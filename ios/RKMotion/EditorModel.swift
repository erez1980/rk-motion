import Foundation
import AVFoundation
import Combine
import Photos
import UIKit
import PhotosUI
import SwiftUI

/// What the app is busy with, so each screen can show the right progress.
enum Work {case importing, analyzing, exporting, previewing, downloading, other}

@MainActor final class EditorModel: ObservableObject {
    @Published private(set) var work: Work?
    @Published var projects: [LocalProject] = []
    @Published var project: LocalProject? {didSet {refreshPlan()}}
    @Published var edit = Edit(clips: []) {didSet {refreshPlan()}}
    @Published var busy = false
    @Published var percent: Double = 0
    @Published var message = ""
    @Published var wholeVideo = false
    @Published var threshold = 0.55
    @Published var movieURL: URL?
    @Published var undoAvailable = false
    @Published var redoAvailable = false
    /// The prepared edit, played only through `PreviewPlayback`, which makes
    /// its own item from it.
    @Published var previewEdit: PreviewEdit?
    @Published var projectBytes: Int64 = 0
    @Published var sourceDimensions: CGSize = .zero
    /// A project of several videos, played one after another as its source.
    @Published private(set) var joinedSource: PreviewEdit?
    var editValidationMessage: String? {
        guard let p = project else {return nil}
        let clips = edit.clips.filter {$0.selected != false}
        guard !clips.isEmpty else {return "בחרו לפחות קטע אחד"}
        if clips.count > Edit.clipLimit {
            return String(format: NSLocalizedString("בסרט אחד יש מקום לעד %@ קטעים. נבחרו %@; בטלו את הבחירה בחלק מהם.", comment: "Too many clips selected"), "\(Edit.clipLimit)", "\(clips.count)")
        }
        if clips.contains(where: {!$0.start.isFinite || !$0.end.isFinite || $0.start < 0 || $0.end <= $0.start || $0.end > p.duration}) {
            return "זמני הקטעים צריכים להיות בתוך הסרטון, והסיום אחרי ההתחלה"
        }
        if clips.contains(where: {p.part(for: $0) == nil}) {return "כל קטע צריך להיות מתוך סרטון אחד"}
        return nil
    }
    var selectedClips: [Clip] {edit.clips.filter {$0.selected != false && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start}}
    /// The finished movie's length, or nil while nothing exportable is chosen.
    var expectedDuration: Double? {
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let fade = (edit.settings["transition"]?.string ?? "cut") != "cut" ? (Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5) : 0
        guard !selectedClips.isEmpty, speed > 0 else {return nil}
        let clips = project.map {LocalEngine.shaped(selectedClips, project: $0, edit: edit)} ?? selectedClips
        return LocalEngine.timeline(clips: clips, speed: speed, transition: fade).last?.end ?? 0
    }
    /// The exported movie's length as the engine will really make it, beat
    /// moves included, worked out again shortly after every change.
    @Published private(set) var plannedDuration: Double?
    private var planTask: Task<Void, Never>?
    /// What to show as the movie's length: the planned one once known.
    var movieDuration: Double? {plannedDuration ?? expectedDuration}
    /// Whether moving cuts to the beat makes the movie a different length.
    var beatChangesLength: Bool {
        guard let planned = plannedDuration, let naive = expectedDuration else {return false}
        return abs(planned - naive) >= 0.05
    }
    private func refreshPlan() {
        planTask?.cancel()
        plannedDuration = nil
        guard let p = project, p.analyzed else {return}
        let snapshot = edit
        planTask = Task {[weak self, engine] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {return}
            let length = await engine.plannedLength(p, edit: snapshot)
            guard !Task.isCancelled else {return}
            self?.plannedDuration = length
        }
    }
    /// Waits for the planned length, for tests.
    func settlePlan() async {await planTask?.value}
    var expectedFormat: String {
        let quality = edit.settings["quality"]?.string ?? "1080"
        let cap: Double? = quality == "original" ? nil : ["720", "whatsapp"].contains(quality) ? 720 : 1080
        let size = LocalEngine.frame(source: sourceDimensions, cap: cap, portrait: edit.settings["aspect"]?.string == "9:16")
        return (sourceDimensions.width > 0 ? "\(Int(size.width))×\(Int(size.height)) · " : "") + "SDR · 30fps"
    }
    /// The song just added, so the music step can offer to choose its start.
    @Published var addedSong: String?
    @Published var saveFailed = false
    @Published var photoPermissionDenied = false
    private let persistence: ProjectPersistence
    init(persistence: ProjectPersistence = ProjectPersistence()) {self.persistence = persistence}
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private let engine = LocalEngine()
    private let continued = ContinuedProcessing.shared
    private var processingSucceeded = false
    @Published private var backgroundFallback = false
    var backgroundDescription: String {
        continued.enabled && !backgroundFallback ? "עיבוד ברקע זמין בגרסה זו. iOS עשויה לעצור את הפעולה אם חסרים משאבים." : "לפעולות ארוכות השאירו את האפליקציה פתוחה; גרסה זו משתמשת בזמן רקע מוגבל."
    }
    private func launchProcessing(title: String, _ launch: @escaping () -> Void) {
        let accepted = continued.start(title: title, launch: {[weak self] in self?.endBackground(); launch()}, expire: {[weak self] in self?.operation?.cancel()})
        backgroundFallback = !accepted
        if !accepted {launch()}
    }
    private var operation: Task<Void, Never>?
    private var suppressedEdit: Edit?
    private var undoStack: [Edit] = [], redoStack: [Edit] = []
    private var backgroundID = UIBackgroundTaskIdentifier.invalid
    var canCancel: Bool {operation != nil}
    var sourceURL: URL? {project.map {LocalStore.file($0.source, project: $0.id)}}

    func restore() async {
        guard !busy, projects.isEmpty, project == nil else {return}
        setBusy(true)
        let recovery = await LocalStore.recoverImports()
        projects = await persistence.load(); setBusy(false)
        if !recovery.rescued.isEmpty {
            message = String(format: NSLocalizedString("שוחזרו %@ סרטונים מייבוא שנקטע. הם מופיעים ברשימת הפרויקטים.", comment: "Videos rescued from an interrupted import"), "\(recovery.rescued.count)")
        } else if recovery.fragmentBytes > 0 {
            message = String(format: NSLocalizedString("נשארו %@ מייבוא שנקטע. אפשר לפנות אותם מתפריט הפרויקט ← ניקוי קבצים זמניים.", comment: "Pieces of an interrupted import that can be cleaned up"), ByteCountFormatter.string(fromByteCount: recovery.fragmentBytes, countStyle: .file))
        }
        guard project == nil, let id = UserDefaults.standard.string(forKey: "localProject"), let saved = projects.first(where: {$0.id == id}) else {return}
        await open(saved)
    }
    func open(_ value: LocalProject) async {
        guard !busy, project?.id != value.id else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        project = value; wholeVideo = value.wholeVideo; edit = value.edit; suppressedEdit = edit
        undoStack = []; redoStack = []; updateUndo()
        movieURL = value.exports.last.map {LocalStore.file($0.file, project: value.id)}
        UserDefaults.standard.set(value.id, forKey: "localProject")
        sourceDimensions = (try? await engine.sourceDimensions(LocalStore.file(value.source, project: value.id))) ?? .zero
        await joinSource(value)
        previewEdit = nil; projectBytes = await persistence.bytes(value); setBusy(false)
        message = value.analyzed ? "הפרויקט נשמר באייפון" : "הסרטון נשמר. אפשר לחדש את הניתוח."
    }
    /// Puts the current project away so a new ride starts from an empty screen.
    func close() async {
        guard !busy, project != nil else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        project = nil; edit = Edit(clips: []); suppressedEdit = edit; movieURL = nil; previewEdit = nil; projectBytes = 0
        sourceDimensions = .zero; joinedSource = nil; undoStack = []; redoStack = []; updateUndo(); wholeVideo = false; message = ""
        UserDefaults.standard.removeObject(forKey: "localProject")
        setBusy(false)
    }
    func changed(from previous: Edit) {
        guard project != nil else {return}
        if let suppressed = suppressedEdit {suppressedEdit = nil; if suppressed == edit {return}}
        undoStack.append(previous); if undoStack.count > 40 {undoStack.removeFirst()}
        redoStack = []; updateUndo(); scheduleSave()
    }
    private func snapshot() -> LocalProject? {
        guard var p = project else {return nil}
        p.edit = edit; project = p; refreshLibrary(p); return p
    }
    private func scheduleSave(immediate: Bool = false) {
        saveTask?.cancel()
        guard let p = snapshot() else {return}
        previewEdit = nil
        revision += 1; let version = revision
        saveTask = Task {
            do {
                if !immediate {try await Task.sleep(for: .milliseconds(350))}
                try Task.checkCancellation()
                try await persistence.save(p, revision: version)
                if version == revision {saveFailed = false}
            } catch is CancellationError {} catch {
                if version == revision {saveFailed = true; message = NSLocalizedString("שמירת הפרויקט נכשלה: ", comment: "Project save failure prefix") + error.localizedDescription}
            }
        }
    }
    @discardableResult func save() async -> Bool {
        saveTask?.cancel(); saveTask = nil
        guard let p = snapshot() else {return true}
        revision += 1; let version = revision
        do {
            try await persistence.save(p, revision: version)
            if version == revision {saveFailed = false}
            return true
        } catch {saveFailed = true; message = NSLocalizedString("שמירת הפרויקט נכשלה: ", comment: "Project save failure prefix") + error.localizedDescription; return false}
    }
    private func refreshLibrary(_ p: LocalProject) {projects.removeAll {$0.id == p.id}; projects.insert(p, at: 0)}
    private func setBusy(_ value: Bool, _ kind: Work = .other) {
        busy = value; work = value ? kind : nil; UIApplication.shared.isIdleTimerDisabled = value
        if value {processingSucceeded = false}
        if value && backgroundID == .invalid {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Finish local processing") {[weak self] in
                self?.operation?.cancel(); self?.endBackground()
            }
        }
        if !value {continued.complete(success: processingSucceeded); operation = nil; endBackground()}
    }
    /// One operation from the picker to a saved project, so "cancel" reaches
    /// whichever part is running: the picker's hand-over or the copy.
    func importPickedVideo(_ item: PhotosPickerItem) {importPickedVideos([item])}
    /// Several picked videos become one project, in the order they were filmed.
    func importPickedVideos(_ items: [PhotosPickerItem]) {
        guard !busy, !items.isEmpty else {return}
        setBusy(true, .importing); percent = 0; message = "האייפון מכין את הקובץ…"
        operation = Task {
            var staged: [URL] = []
            do {
                for item in items {
                    guard let picked = try await item.loadTransferable(type: PickedMovie.self) else {throw AppError(message: "לא ניתן לקרוא את הסרטון שנבחר.")}
                    staged.append(picked.url); try Task.checkCancellation()
                }
                await runImport(await Self.chronological(staged))
            } catch is CancellationError {finishImport(nil, cancelled: true)}
            catch {finishImport(nil, error: error)}
            // Moved into the project when the import succeeded; otherwise it
            // is this operation's own copy and goes with it.
            for url in staged where FileManager.default.fileExists(atPath: url.path) {try? FileManager.default.removeItem(at: url)}
        }
    }
    func importVideo(_ file: URL) async {await importVideos([file])}
    func importVideos(_ files: [URL]) async {
        guard !busy else {message = "המתינו לסיום הפעולה הנוכחית"; return}
        guard !files.isEmpty else {return}
        setBusy(true, .importing); percent = 0
        let task = Task {await runImport(await Self.chronological(files))}
        operation = task
        await task.value
    }
    /// The videos in the order they were filmed; one without a date keeps
    /// its place among the order they were picked in.
    nonisolated static func chronological(_ files: [URL]) async -> [URL] {
        guard files.count > 1 else {return files}
        var dated: [(url: URL, date: Date?, index: Int)] = []
        for (index, url) in files.enumerated() {
            let access = url.startAccessingSecurityScopedResource()
            defer {if access {url.stopAccessingSecurityScopedResource()}}
            var date: Date?
            if let item = try? await AVURLAsset(url: url).load(.creationDate) {date = try? await item.load(.dateValue)}
            dated.append((url, date, index))
        }
        // Undated videos keep their picked order; dated ones are compared by date.
        guard dated.allSatisfy({$0.date != nil}) else {return files}
        return dated.sorted {($0.date!, $0.index) < ($1.date!, $1.index)}.map(\.url)
    }
    /// Writes a manifest, copies the videos into the new project's folder in
    /// pieces, and only then saves the project. An interruption leaves the
    /// manifest behind for `restore` to find; a cancellation removes this
    /// import's own partial copy and nothing else.
    private func runImport(_ files: [URL]) async {
        guard await save() else {setBusy(false); return}
        guard let first = files.first else {setBusy(false); return}
        let copying = files.count > 1 ? NSLocalizedString("העתקת הסרטונים לאחסון המקומי…", comment: "Copying several videos") : NSLocalizedString("העתקת הסרטון לאחסון המקומי…", comment: "Copying the video")
        message = copying
        let name = UUID(uuidString: first.deletingPathExtension().lastPathComponent) == nil ? first.lastPathComponent : NSLocalizedString("סרטון ", comment: "Default project name prefix") + Date().formatted(date: .abbreviated, time: .shortened)
        var p = LocalProject(name: name, source: "")
        p.wholeVideo = wholeVideo
        p.edit.settings.merge(Edit.newMovieSettings(wholeVideo: p.wholeVideo)) {$1}
        do {
            let size = files.reduce(Int64(0)) {$0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)}
            let targets = files.map {"source-" + UUID().uuidString + "." + ($0.pathExtension.isEmpty ? "mov" : $0.pathExtension)}
            try LocalStore.writeManifest(.init(name: name, source: targets[0], sources: files.count > 1 ? targets : nil, bytes: size, wholeVideo: p.wholeVideo), project: p.id)
            for (index, file) in files.enumerated() {
                let share = 1 / Double(files.count), base = Double(index) * share
                let copied = try await LocalStore.importFile(file, project: p.id, prefix: "source", named: targets[index]) {[weak self] fraction in
                    await self?.progress(base + fraction * share, copying)
                }
                if index == 0 {p.source = copied}
                try Task.checkCancellation()
            }
            if files.count > 1 {
                guard let parts = await LocalStore.laidOut(targets, project: p.id) else {throw AppError(message: "לא ניתן לקרוא את הסרטון שנבחר.")}
                p.parts = parts
            }
            try Task.checkCancellation()
            revision += 1; try await persistence.save(p, revision: revision)
            LocalStore.finishImport(project: p.id)
            project = p; edit = p.edit; suppressedEdit = edit; movieURL = nil
            undoStack = []; redoStack = []; updateUndo(); refreshLibrary(p)
            UserDefaults.standard.set(p.id, forKey: "localProject")
            sourceDimensions = (try? await engine.sourceDimensions(LocalStore.file(p.source, project: p.id))) ?? .zero
            await joinSource(p)
            previewEdit = nil; projectBytes = await persistence.bytes(p)
            processingSucceeded = true; setBusy(false); analyze()
        } catch is CancellationError {finishImport(p.id, cancelled: true)}
        catch {finishImport(p.id, error: error)}
    }
    /// Prepares the joined videos to play as the source; nothing for one video.
    private func joinSource(_ p: LocalProject) async {
        if p.joinsVideos {joinedSource = try? await engine.joinedSource(p)} else {joinedSource = nil}
    }
    private func finishImport(_ id: String?, cancelled: Bool = false, error: Error? = nil) {
        if let id {LocalStore.abandonImport(project: id)}
        message = cancelled ? "ייבוא הסרטון בוטל" : error?.localizedDescription ?? ""
        if busy {setBusy(false)}
    }
    func analyze() {
        guard !busy, var p = project else {return}
        p.wholeVideo = wholeVideo; project = p
        setBusy(true, .analyzing); percent = 0; message = "ניתוח באייפון…"
        let whole = wholeVideo
        launchProcessing(title: "ניתוח סרטון") { [self] in
          operation = Task {
            guard await save() else {setBusy(false); return}
            do {
                let result = try await engine.analyze(p.files.map {LocalStore.file($0, project: p.id)}, whole: whole) {[weak self] fraction, text in
                    await self?.progress(fraction, text)
                }
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                // Without its saved signals a reading could not be switched to another kind, so it is not kept.
                let stored = result.signals.map {(try? LocalStore.writeSignals($0, project: p.id)) != nil} ?? false
                current.duration = result.duration; current.scores = result.scores; current.analyzed = true; current.reading = stored ? result.reading : nil
                if current.joinsVideos {current.parts = ProjectPart.laid(current.files, durations: result.durations)}
                project = current; edit.clips = whole ? result.clips : fittedToLength(result.clips, settings: edit.settings); edit.settings["wholeVideo"] = .flag(whole)
                if let kind = result.reading?.kind {
                    edit.settings["contentKind"] = .text(kind.rawValue); edit.settings["muteOriginal"] = .flag(kind.mutesOriginal)
                    // Slow motion on the strongest moment, except where people are talking.
                    edit.settings["slowPeak"] = .flag(kind != .talk)
                }
                previewEdit = nil; suppressedEdit = edit; undoStack = []; redoStack = []; updateUndo()
                if await save() {processingSucceeded = true; message = result.clips.isEmpty ? "לא נמצאו רגעים בולטים. שנו רגישות או הוסיפו קטע ידני." : "הניתוח הושלם — כל העיבוד נעשה באייפון"}
            } catch is CancellationError {message = "הניתוח בוטל. הסרטון נשמר ואפשר לנסות שוב."}
            catch {message = error.localizedDescription}
            setBusy(false)
          }
        }
    }
    private func progress(_ fraction: Double, _ text: String) {percent = fraction * 100; message = text; continued.update(fraction, subtitle: text)}
    func retune() {
        guard let p = project, !busy else {return}
        let previous = edit
        edit.clips = fittedToLength(p.fitted(LocalEngine.ranges(scores: p.scores, duration: p.duration, threshold: threshold)) + edit.clips.filter {$0.manual == true}, settings: edit.settings)
        wholeVideo = false; project?.wholeVideo = false; edit.settings["wholeVideo"] = .flag(false)
        changed(from: previous); suppressedEdit = edit
    }
    /// The start in `song` that lands its drop on the movie's strongest
    /// moment, with the drop and the moment in their own seconds; nil when
    /// the song has no clear drop or it comes too early to reach the moment.
    /// Only the first song plays from the movie's first second, so only it
    /// can be lined up this way.
    func dropStart(for song: LocalMusic) async -> (start: Double, drop: Double, peak: Double)? {
        guard let p = project, !p.scores.isEmpty, song.duration > 8, p.music.first?.id == song.id else {return nil}
        let bins = Int(song.duration * 4)
        guard let levels = try? await LocalEngine.waveform(LocalStore.file(song.file, project: p.id), bins: bins), levels.count == bins,
              let drop = Drop.find(levels, rate: Double(bins) / song.duration) else {return nil}
        // Beat moves follow the song's start and shift the moment, so the
        // start is worked out on the exported timeline until it settles.
        var trial = edit, result: (start: Double, drop: Double, peak: Double)?
        trial.setMusicStart(0, for: song.id)
        for _ in 0..<3 {
            guard let peak = await engine.peakTime(p, edit: trial), let start = Drop.start(drop: drop, peak: peak) else {return result}
            if let result, abs(result.start - start) < 0.02 {break}
            result = (start, drop, peak)
            trial.setMusicStart(start, for: song.id)
        }
        return result
    }
    /// Edits the video as another kind of content: scores the scan's saved
    /// signals with that kind's recipe, picks the moments again and sets its
    /// source sound. Undo brings the previous kind back.
    func setKind(_ kind: ContentKind) {
        guard !busy, let p = project, p.reading != nil, p.reading?.kind != kind,
              let signals = LocalStore.readSignals(project: p.id) else {return}
        let previous = edit
        apply(kind, signals: signals)
        edit.settings["contentKind"] = .text(kind.rawValue); edit.settings["muteOriginal"] = .flag(kind.mutesOriginal)
        edit.clips = fittedToLength(p.fitted(LocalEngine.ranges(scores: project?.scores ?? [], duration: p.duration, threshold: threshold)) + edit.clips.filter {$0.manual == true}, settings: edit.settings)
        wholeVideo = false; project?.wholeVideo = false; edit.settings["wholeVideo"] = .flag(false)
        changed(from: previous); suppressedEdit = edit
        message = String(format: NSLocalizedString("הסרט נערך מחדש כ%@. ניתן לבטל את השינוי.", comment: "Content kind changed"), kind.title)
    }
    private func apply(_ kind: ContentKind, signals: Signals) {
        project?.reading?.kind = kind; project?.scores = signals.scores(for: kind)
    }
    /// After undo or redo, the scores follow the kind the restored edit was made as.
    private func followKind() {
        guard let raw = edit.settings["contentKind"]?.string, let kind = ContentKind(rawValue: raw),
              let p = project, p.reading != nil, p.reading?.kind != kind,
              let signals = LocalStore.readSignals(project: p.id) else {return}
        apply(kind, signals: signals)
    }
    func shuffleClips() {
        guard !busy, edit.clips.count > 1 else {return}
        var generator = SystemRandomNumberGenerator()
        edit.clips = ClipPicker.shuffled(edit.clips, using: &generator)
    }
    /// `seconds` is the finished movie's length, so playback speed counts.
    func autoPick(seconds: Double) {
        guard !busy, !edit.clips.isEmpty else {return}
        edit.clips = Self.picked(edit.clips, seconds: seconds, settings: edit.settings)
    }
    /// The movie length the clip choice aims at: "30", "45", "60" seconds,
    /// or "all" for every suggested moment. A new movie aims at 45 seconds.
    var targetLength: String {edit.settings["targetLength"]?.string ?? Edit.defaultLength}
    /// Chooses the clips again for another length, as one change to undo.
    func pickLength(_ length: String) {
        guard !busy, !edit.clips.isEmpty else {return}
        var next = edit
        next.settings["targetLength"] = .text(length)
        next.clips = fittedToLength(next.clips, settings: next.settings)
        edit = next
    }
    /// Changes a setting that stretches or shortens the movie (speed, transitions)
    /// and chooses the clips again so it still runs the chosen length.
    func setTiming(_ key: String, _ value: String) {
        var next = edit
        next.settings[key] = .text(value)
        if next.clips.count > 1, next.settings["wholeVideo"]?.bool != true, Double(next.settings["targetLength"]?.string ?? Edit.defaultLength) != nil {
            next.clips = fittedToLength(next.clips, settings: next.settings)
        }
        edit = next
    }
    /// The clips chosen for the length in `settings`; "all" chooses every one.
    func fittedToLength(_ clips: [Clip], settings: [String: Setting]) -> [Clip] {
        let length = settings["targetLength"]?.string ?? Edit.defaultLength
        guard let seconds = Double(length), seconds > 0 else {
            return Edit.capped(clips.map {var clip = $0; clip.selected = true; return clip})
        }
        return Self.picked(clips, seconds: seconds, settings: settings)
    }
    private static func picked(_ clips: [Clip], seconds: Double, settings: [String: Setting]) -> [Clip] {
        guard !clips.isEmpty else {return clips}
        let speed = Double(settings["speed"]?.string ?? "1") ?? 1
        let overlap = (settings["transition"]?.string ?? "cut") != "cut" ? (Double(settings["transitionDuration"]?.string ?? "0.5") ?? 0.5) : 0
        return ClipPicker.autoPick(clips, seconds: seconds, speed: speed.isFinite && speed > 0 ? speed : 1, transition: overlap.isFinite ? overlap : 0)
    }
    func undo() {guard let previous = undoStack.popLast() else {return}; redoStack.append(edit); edit = previous; wholeVideo = previous.settings["wholeVideo"]?.bool ?? false; project?.wholeVideo = wholeVideo; suppressedEdit = previous; followKind(); updateUndo(); scheduleSave()}
    func redo() {guard let next = redoStack.popLast() else {return}; undoStack.append(edit); edit = next; wholeVideo = next.settings["wholeVideo"]?.bool ?? false; project?.wholeVideo = wholeVideo; suppressedEdit = next; followKind(); updateUndo(); scheduleSave()}
    private func updateUndo() {undoAvailable = !undoStack.isEmpty; redoAvailable = !redoStack.isEmpty}
    func importMusic(_ file: URL) async {
        guard !busy, var p = project else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        // Refresh the snapshot after flushing current edits.
        p = project ?? p
        message = "הוספת מוזיקה מקומית…"
        var imported: String?
        do {
            let name = try await LocalStore.importFile(file, project: p.id, prefix: "music"); imported = name
            let url = LocalStore.file(name, project: p.id)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {throw AppError(message: "בחרו קובץ שמע תקין.")}
            let song = LocalMusic(file: name, name: file.deletingPathExtension().lastPathComponent, duration: duration)
            p.music.append(song)
            project = p; if await save() {message = "המוזיקה נשמרה באייפון"; addedSong = song.id}
        } catch {if let imported {try? FileManager.default.removeItem(at: LocalStore.file(imported, project: p.id))}; message = error.localizedDescription}
        setBusy(false)
    }
    /// Downloads a song's audio from a YouTube link, then adds it exactly as a
    /// song picked from Files would be added.
    func importYouTube(_ text: String) {
        guard let link = YouTubeMusic.link(in: text) else {message = "הדביקו קישור לסרטון YouTube."; return}
        importYouTube(link: link)
    }
    func importYouTube(link: URL) {
        guard !busy, project != nil else {return}
        setBusy(true, .downloading); percent = 0; message = "הורדת השמע מ־YouTube…"
        operation = Task {
            do {
                let file = try await YouTubeMusic.download(link, into: LocalStore.imports) {[weak self] fraction in
                    await self?.progress(fraction, "הורדת השמע מ־YouTube…")
                }
                setBusy(false)
                await importMusic(file)
                return
            } catch is CancellationError {message = "ההורדה בוטלה."}
            catch {message = error.localizedDescription}
            setBusy(false)
        }
    }
    /// The song leaves the project in memory first, so a save made meanwhile
    /// (the app going to the background) cannot list it again; its file goes
    /// only once a project without it is on disk.
    func removeMusic(_ id: String) async {
        guard !busy, var p = project, let song = p.music.first(where: {$0.id == id}) else {return}
        setBusy(true)
        saveTask?.cancel(); saveTask = nil
        p.edit = edit; p.music.removeAll {$0.id == id}
        project = p; refreshLibrary(p); previewEdit = nil
        revision += 1
        do {
            if let warning = try await persistence.removeMusic(song, from: p, revision: revision) {message = warning}
        } catch {
            project?.music = (project?.music ?? []) + [song]; message = error.localizedDescription
            if let restored = project {refreshLibrary(restored)}
        }
        if let current = project {projectBytes = await persistence.bytes(current)}
        setBusy(false)
    }
    func exportMovie() {
        guard !busy, let p = project, p.analyzed else {return}
        if let problem = editValidationMessage {message = problem; return}
        let snapshot = edit
        setBusy(true, .exporting); percent = 0; message = "ייצוא באייפון…"
        let file = "RK-Motion-" + UUID().uuidString + ".mp4", output = LocalStore.file(file, project: p.id)
        launchProcessing(title: "ייצוא סרטון") { [self] in
          operation = Task {
            guard await save() else {setBusy(false); return}
            do {
                let duration = try await engine.export(p, edit: snapshot, output: output) {[weak self] fraction, text in await self?.progress(fraction, text)}
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                current.exports.append(LocalExport(file: file, duration: duration)); project = current; movieURL = output
                if await save() {processingSucceeded = true; projectBytes = await persistence.bytes(current); message = "הסרט נוצר באייפון ומוכן לשמירה ושיתוף"}
            } catch is CancellationError {try? FileManager.default.removeItem(at: output); message = "הייצוא בוטל. העריכה נשמרה."}
            catch {try? FileManager.default.removeItem(at: output); message = error.localizedDescription}
            setBusy(false)
          }
        }
    }
    func cancel() {operation?.cancel()}
    /// Waits for the save already scheduled, for tests and orderly shutdown.
    func settleSaves() async {await saveTask?.value}
    func pause() {
        scheduleSave(immediate: true)
        if busy && !continued.hasActiveTask && backgroundID == .invalid {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Finish local processing") {[weak self] in
                self?.operation?.cancel(); self?.endBackground()
            }
        }
    }
    func foreground() {if !busy {endBackground()}}
    private func endBackground() {if backgroundID != .invalid {UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid}}
    func reset() async {
        guard !busy, let p = project else {return}
        // A save already on its way is cancelled, and the persistence actor
        // refuses any write for a deleted project, so none can recreate it.
        setBusy(true); saveTask?.cancel()
        do {
            try await persistence.deleteProject(p.id)
            await Thumbnails.shared.forget(p.id)
            projects.removeAll {$0.id == p.id}; project = nil; movieURL = nil; previewEdit = nil; joinedSource = nil; projectBytes = 0; edit = Edit(clips: []); suppressedEdit = edit
            UserDefaults.standard.removeObject(forKey: "localProject"); message = "הפרויקט נמחק מהאייפון"
        } catch {message = error.localizedDescription}
        setBusy(false)
    }
    /// Deletes a project from the home screen; the open one goes through `reset`.
    func delete(_ target: LocalProject) async {
        guard !busy else {return}
        if target.id == project?.id {await reset(); return}
        setBusy(true)
        do {
            try await persistence.deleteProject(target.id)
            await Thumbnails.shared.forget(target.id)
            projects.removeAll {$0.id == target.id}; message = "הפרויקט נמחק מהאייפון"
        } catch {message = error.localizedDescription}
        setBusy(false)
    }
    /// Gives the open project a name of the rider's own.
    func rename(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !busy, !trimmed.isEmpty, var p = project, p.name != trimmed else {return}
        p.name = trimmed; project = p; refreshLibrary(p); scheduleSave(immediate: true)
    }
    func applyWholeVideo() {
        guard !busy, let p = project, p.analyzed else {return}
        if !wholeVideo && p.scores.isEmpty {analyze(); return}
        var previous = edit; previous.settings["wholeVideo"] = .flag(p.wholeVideo)
        edit.settings["wholeVideo"] = .flag(wholeVideo)
        edit.clips = wholeVideo ? p.wholeClips : fittedToLength(p.fitted(LocalEngine.ranges(scores: p.scores, duration: p.duration, threshold: threshold)), settings: edit.settings)
        project?.wholeVideo = wholeVideo
        changed(from: previous); suppressedEdit = edit
        message = wholeVideo ? "כל הסרטון נבחר. ניתן לבטל את השינוי." : "הרגעים הבולטים הוחזרו. ניתן לבטל את השינוי."
    }
    /// As with a song: out of the project in memory first, then on disk, and
    /// only then is the file removed.
    func deleteExport(_ result: LocalExport) async {
        guard !busy, var p = project else {return}
        setBusy(true)
        saveTask?.cancel(); saveTask = nil
        let previous = p.exports
        p.edit = edit; p.exports.removeAll {$0.id == result.id}
        project = p; refreshLibrary(p)
        if movieURL?.lastPathComponent == result.file {movieURL = nil}
        revision += 1
        do {
            let warning = try await persistence.deleteExport(result, from: p, revision: revision)
            message = warning.map {NSLocalizedString("הסרט הוסר מהרשימה אך פינוי הקובץ נכשל: ", comment: "Export removed but file left behind") + $0} ?? "הסרט שנוצר נמחק מהאפליקציה"
        } catch {
            project?.exports = previous; message = error.localizedDescription
            if let restored = project {refreshLibrary(restored)}
        }
        if let current = project {projectBytes = await persistence.bytes(current)}
        setBusy(false)
    }
    func preview() {
        guard !busy, let p = project, p.analyzed else {return}
        if let problem = editValidationMessage {message = problem; return}
        let snapshot = edit; setBusy(true, .previewing); percent = 0
        launchProcessing(title: "תצוגה מקדימה של העריכה") { [self] in
          operation = Task {
            guard await save() else {setBusy(false); return}
            do {previewEdit = try await engine.previewEdit(p, edit: snapshot); processingSucceeded = true; message = "תצוגה מקדימה של העריכה — ללא יצירת קובץ"}
            catch is CancellationError {message = "התצוגה המקדימה בוטלה"}
            catch {message = error.localizedDescription}
            setBusy(false)
          }
        }
    }
    func cleanTemporaryFiles() async {
        guard !busy else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        do {
            let bytes = try await persistence.cleanTemporaryFiles()
            projects = await persistence.load()
            if let p = project {projectBytes = await persistence.bytes(p)}
            message = NSLocalizedString("הניקוי הסתיים. פונו ", comment: "Cleanup finished prefix") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } catch {message = NSLocalizedString("הניקוי לא הושלם: ", comment: "Cleanup failure prefix") + error.localizedDescription}
        setBusy(false)
    }
    func saveToPhotos(_ file: URL) async {
        guard !busy else {return}
        setBusy(true); defer {setBusy(false)}
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        photoPermissionDenied = permission != .authorized && permission != .limited
        guard !photoPermissionDenied else {message = "אפשרו שמירה בתמונות בהגדרות האייפון"; return}
        do {try await PHPhotoLibrary.shared().performChanges {PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)}; message = "הסרט נשמר בתמונות"}
        catch {message = error.localizedDescription}
    }
}

#if DEBUG
extension EditorModel {
    /// Removes the rides earlier UI test runs made, so the simulator's
    /// project list does not fill up with them.
    func discardTestRides() async {
        let mark = "rk-ui-fixture-"
        if project?.name.hasPrefix(mark) == true {await reset()}
        for old in projects where old.name.hasPrefix(mark) && old.id != project?.id {
            try? await persistence.deleteProject(old.id)
            await Thumbnails.shared.forget(old.id)
        }
        projects.removeAll {$0.name.hasPrefix(mark) && $0.id != project?.id}
    }
}
#endif
