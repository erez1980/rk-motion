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
        return nil
    }
    var selectedClips: [Clip] {edit.clips.filter {$0.selected != false && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start}}
    /// The finished movie's length, or nil while nothing exportable is chosen.
    var expectedDuration: Double? {
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let fade = (edit.settings["transition"]?.string ?? "cut") != "cut" ? (Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5) : 0
        guard !selectedClips.isEmpty, speed > 0 else {return nil}
        return LocalEngine.timeline(clips: selectedClips, speed: speed, transition: fade).last?.end ?? 0
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
        previewEdit = nil; projectBytes = await persistence.bytes(value); setBusy(false)
        message = value.analyzed ? "הפרויקט נשמר באייפון" : "הסרטון נשמר. אפשר לחדש את הניתוח."
    }
    /// Puts the current project away so a new ride starts from an empty screen.
    func close() async {
        guard !busy, project != nil else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        project = nil; edit = Edit(clips: []); suppressedEdit = edit; movieURL = nil; previewEdit = nil; projectBytes = 0
        sourceDimensions = .zero; undoStack = []; redoStack = []; updateUndo(); wholeVideo = false; message = ""
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
    func importPickedVideo(_ item: PhotosPickerItem) {
        guard !busy else {return}
        setBusy(true, .importing); percent = 0; message = "האייפון מכין את הקובץ…"
        operation = Task {
            var staged: URL?
            do {
                guard let picked = try await item.loadTransferable(type: PickedMovie.self) else {throw AppError(message: "לא ניתן לקרוא את הסרטון שנבחר.")}
                staged = picked.url; try Task.checkCancellation()
                await runImport(picked.url)
            } catch is CancellationError {finishImport(nil, cancelled: true)}
            catch {finishImport(nil, error: error)}
            // Moved into the project when the import succeeded; otherwise it
            // is this operation's own copy and goes with it.
            if let staged, FileManager.default.fileExists(atPath: staged.path) {try? FileManager.default.removeItem(at: staged)}
        }
    }
    func importVideo(_ file: URL) async {
        guard !busy else {message = "המתינו לסיום הפעולה הנוכחית"; return}
        setBusy(true, .importing); percent = 0
        let task = Task {await runImport(file)}
        operation = task
        await task.value
    }
    /// Writes a manifest, copies the video into the new project's folder in
    /// pieces, and only then saves the project. An interruption leaves the
    /// manifest behind for `restore` to find; a cancellation removes this
    /// import's own partial copy and nothing else.
    private func runImport(_ file: URL) async {
        guard await save() else {setBusy(false); return}
        message = "מעתיקה את הסרטון לאחסון המקומי…"
        let name = UUID(uuidString: file.deletingPathExtension().lastPathComponent) == nil ? file.lastPathComponent : NSLocalizedString("סרטון ", comment: "Default project name prefix") + Date().formatted(date: .abbreviated, time: .shortened)
        var p = LocalProject(name: name, source: "")
        p.wholeVideo = wholeVideo
        do {
            let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let target = "source-" + UUID().uuidString + "." + (file.pathExtension.isEmpty ? "mov" : file.pathExtension)
            try LocalStore.writeManifest(.init(name: name, source: target, bytes: size, wholeVideo: p.wholeVideo), project: p.id)
            p.source = try await LocalStore.importFile(file, project: p.id, prefix: "source", named: target) {[weak self] fraction in
                await self?.progress(fraction, "מעתיקה את הסרטון לאחסון המקומי…")
            }
            try Task.checkCancellation()
            revision += 1; try await persistence.save(p, revision: revision)
            LocalStore.finishImport(project: p.id)
            project = p; edit = p.edit; suppressedEdit = edit; movieURL = nil
            undoStack = []; redoStack = []; updateUndo(); refreshLibrary(p)
            UserDefaults.standard.set(p.id, forKey: "localProject")
            sourceDimensions = (try? await engine.sourceDimensions(LocalStore.file(p.source, project: p.id))) ?? .zero
            previewEdit = nil; projectBytes = await persistence.bytes(p)
            processingSucceeded = true; setBusy(false); analyze()
        } catch is CancellationError {finishImport(p.id, cancelled: true)}
        catch {finishImport(p.id, error: error)}
    }
    private func finishImport(_ id: String?, cancelled: Bool = false, error: Error? = nil) {
        if let id {LocalStore.abandonImport(project: id)}
        message = cancelled ? "ייבוא הסרטון בוטל" : error?.localizedDescription ?? ""
        if busy {setBusy(false)}
    }
    func analyze() {
        guard !busy, var p = project else {return}
        p.wholeVideo = wholeVideo; project = p
        setBusy(true, .analyzing); percent = 0; message = "מנתחת באייפון…"
        let whole = wholeVideo
        launchProcessing(title: "ניתוח סרטון") { [self] in
          operation = Task {
            guard await save() else {setBusy(false); return}
            do {
                let result = try await engine.analyze(LocalStore.file(p.source, project: p.id), whole: whole) {[weak self] fraction, text in
                    await self?.progress(fraction, text)
                }
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                if let signals = result.signals {try? LocalStore.writeSignals(signals, project: p.id)}
                current.duration = result.duration; current.scores = result.scores; current.analyzed = true; current.reading = result.reading
                project = current; edit.clips = result.clips; edit.settings["wholeVideo"] = .flag(whole)
                if let kind = result.reading?.kind {
                    edit.settings["contentKind"] = .text(kind.rawValue); edit.settings["muteOriginal"] = .flag(kind.mutesOriginal)
                }
                previewEdit = nil; suppressedEdit = edit; undoStack = []; redoStack = []; updateUndo()
                if await save() {processingSucceeded = true; message = result.clips.isEmpty ? "לא זוהו קטעי פעילות. שנו רגישות או הוסיפו קטע ידני." : "הניתוח הושלם — כל העיבוד נעשה באייפון"}
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
        edit.clips = LocalEngine.ranges(scores: p.scores, duration: p.duration, threshold: threshold) + edit.clips.filter {$0.manual == true}
        wholeVideo = false; project?.wholeVideo = false; edit.settings["wholeVideo"] = .flag(false)
        changed(from: previous); suppressedEdit = edit
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
        edit.clips = LocalEngine.ranges(scores: project?.scores ?? [], duration: p.duration, threshold: threshold) + edit.clips.filter {$0.manual == true}
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
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let overlap = (edit.settings["transition"]?.string ?? "cut") != "cut" ? (Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5) : 0
        edit.clips = ClipPicker.autoPick(edit.clips, seconds: seconds, speed: speed.isFinite && speed > 0 ? speed : 1, transition: overlap.isFinite ? overlap : 0)
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
        message = "מוסיפה מוזיקה מקומית…"
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
        setBusy(true, .downloading); percent = 0; message = "מורידה את השמע מ־YouTube…"
        operation = Task {
            do {
                let file = try await YouTubeMusic.download(link, into: LocalStore.imports) {[weak self] fraction in
                    await self?.progress(fraction, "מורידה את השמע מ־YouTube…")
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
        setBusy(true, .exporting); percent = 0; message = "מייצאת באייפון…"
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
            projects.removeAll {$0.id == p.id}; project = nil; movieURL = nil; previewEdit = nil; projectBytes = 0; edit = Edit(clips: []); suppressedEdit = edit
            UserDefaults.standard.removeObject(forKey: "localProject"); message = "הפרויקט נמחק מהאייפון"
        } catch {message = error.localizedDescription}
        setBusy(false)
    }
    func applyWholeVideo() {
        guard !busy, let p = project, p.analyzed else {return}
        if !wholeVideo && p.scores.isEmpty {analyze(); return}
        var previous = edit; previous.settings["wholeVideo"] = .flag(p.wholeVideo)
        edit.settings["wholeVideo"] = .flag(wholeVideo)
        edit.clips = wholeVideo ? [Clip(start: 0, end: p.duration)] : LocalEngine.ranges(scores: p.scores, duration: p.duration, threshold: threshold)
        project?.wholeVideo = wholeVideo
        changed(from: previous); suppressedEdit = edit
        message = wholeVideo ? "כל הסרטון נבחר. ניתן לבטל את השינוי." : "הצעות הפעילות הוחזרו. ניתן לבטל את השינוי."
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
