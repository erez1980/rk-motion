import Foundation
import AVFoundation
import Combine
import Photos
import UIKit

@MainActor final class EditorModel: ObservableObject {
    @Published var projects: [LocalProject] = []
    @Published var project: LocalProject?
    @Published var edit = Edit(clips: [])
    @Published var busy = false
    @Published var percent: Double = 0
    @Published var message = ""
    @Published var wholeVideo = false
    @Published var threshold = 0.55
    @Published var movieURL: URL?
    @Published var undoAvailable = false
    @Published var redoAvailable = false
    @Published var previewItem: AVPlayerItem?
    @Published var projectBytes: Int64 = 0
    @Published var saveFailed = false
    private let persistence = ProjectPersistence()
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private let engine = LocalEngine()
    private var operation: Task<Void, Never>?
    private var suppressedEdit: Edit?
    private var undoStack: [Edit] = [], redoStack: [Edit] = []
    private var backgroundID = UIBackgroundTaskIdentifier.invalid
    var canCancel: Bool {operation != nil}
    var sourceURL: URL? {project.map {LocalStore.file($0.source, project: $0.id)}}

    func restore() async {
        guard !busy, projects.isEmpty, project == nil else {return}
        setBusy(true); projects = await persistence.load(); setBusy(false)
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
        previewItem = nil; projectBytes = await persistence.bytes(value); setBusy(false)
        message = value.analyzed ? "הפרויקט נשמר באייפון" : "הסרטון נשמר. אפשר לחדש את הניתוח."
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
        previewItem = nil
        revision += 1; let version = revision
        saveTask = Task {
            do {
                if !immediate {try await Task.sleep(for: .milliseconds(350))}
                try Task.checkCancellation()
                try await persistence.save(p, revision: version)
                if version == revision {saveFailed = false}
            } catch is CancellationError {} catch {
                if version == revision {saveFailed = true; message = "שמירת הפרויקט נכשלה: " + error.localizedDescription}
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
        } catch {saveFailed = true; message = "שמירת הפרויקט נכשלה: " + error.localizedDescription; return false}
    }
    private func refreshLibrary(_ p: LocalProject) {projects.removeAll {$0.id == p.id}; projects.insert(p, at: 0)}
    private func setBusy(_ value: Bool) {
        busy = value; UIApplication.shared.isIdleTimerDisabled = value
        if value && backgroundID == .invalid {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Finish local processing") {[weak self] in
                self?.operation?.cancel(); self?.endBackground()
            }
        }
        if !value {operation = nil; endBackground()}
    }
    func importVideo(_ file: URL) async {
        guard !busy else {message = "המתינו לסיום הפעולה הנוכחית"; return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        percent = 0; message = "מעתיקה את הסרטון לאחסון המקומי…"
        let name = UUID(uuidString: file.deletingPathExtension().lastPathComponent) == nil ? file.lastPathComponent : "רכיבה " + Date().formatted(date: .abbreviated, time: .shortened)
        var p = LocalProject(name: name, source: "")
        p.wholeVideo = wholeVideo
        do {
            p.source = try await LocalStore.importFile(file, project: p.id, prefix: "source")
            revision += 1; try await persistence.save(p, revision: revision); project = p; edit = p.edit; suppressedEdit = edit; movieURL = nil
            undoStack = []; redoStack = []; updateUndo(); refreshLibrary(p)
            UserDefaults.standard.set(p.id, forKey: "localProject")
            previewItem = nil; projectBytes = await persistence.bytes(p)
            setBusy(false); analyze()
        } catch {setBusy(false); message = error.localizedDescription; try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
    }
    func analyze() {
        guard !busy, var p = project else {return}
        p.wholeVideo = wholeVideo; project = p
        setBusy(true); percent = 0; message = "מנתחת באייפון…"
        let whole = wholeVideo
        operation = Task {
            guard await save() else {setBusy(false); return}
            do {
                let (duration, scores, clips) = try await engine.analyze(LocalStore.file(p.source, project: p.id), whole: whole) {[weak self] fraction, text in
                    await self?.progress(fraction, text)
                }
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                current.duration = duration; current.scores = scores; current.analyzed = true
                project = current; edit.clips = clips; edit.settings["wholeVideo"] = .flag(whole); previewItem = nil; suppressedEdit = edit; undoStack = []; redoStack = []; updateUndo()
                if await save() {message = clips.isEmpty ? "לא זוהו קטעי פעילות. שנו רגישות או הוסיפו קטע ידני." : "הניתוח הושלם — כל העיבוד נעשה באייפון"}
            } catch is CancellationError {message = "הניתוח בוטל. הסרטון נשמר ואפשר לנסות שוב."}
            catch {message = error.localizedDescription}
            setBusy(false)
        }
    }
    private func progress(_ fraction: Double, _ text: String) {percent = fraction * 100; message = text}
    func retune() {
        guard let p = project, !busy else {return}
        let previous = edit
        edit.clips = LocalEngine.ranges(scores: p.scores, duration: p.duration, threshold: threshold) + edit.clips.filter {$0.manual == true}
        wholeVideo = false; project?.wholeVideo = false; edit.settings["wholeVideo"] = .flag(false)
        changed(from: previous); suppressedEdit = edit
    }
    func undo() {guard let previous = undoStack.popLast() else {return}; redoStack.append(edit); edit = previous; wholeVideo = previous.settings["wholeVideo"]?.bool ?? false; project?.wholeVideo = wholeVideo; suppressedEdit = previous; updateUndo(); scheduleSave()}
    func redo() {guard let next = redoStack.popLast() else {return}; undoStack.append(edit); edit = next; wholeVideo = next.settings["wholeVideo"]?.bool ?? false; project?.wholeVideo = wholeVideo; suppressedEdit = next; updateUndo(); scheduleSave()}
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
            p.music.append(LocalMusic(file: name, name: file.lastPathComponent, duration: duration))
            project = p; if await save() {message = "המוזיקה נשמרה באייפון"}
        } catch {if let imported {try? FileManager.default.removeItem(at: LocalStore.file(imported, project: p.id))}; message = error.localizedDescription}
        setBusy(false)
    }
    func removeMusic(_ id: String) async {
        guard !busy, var p = project, let song = p.music.first(where: {$0.id == id}) else {return}
        p.music.removeAll {$0.id == id}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        p.edit = edit
        revision += 1
        do {try await persistence.save(p, revision: revision); project = p; refreshLibrary(p); previewItem = nil}
        catch {message = error.localizedDescription; setBusy(false); return}
        try? FileManager.default.removeItem(at: LocalStore.file(song.file, project: p.id))
        projectBytes = await persistence.bytes(p); setBusy(false)
    }
    func exportMovie() {
        guard !busy, let p = project, p.analyzed else {return}
        let snapshot = edit
        setBusy(true); percent = 0; message = "מייצאת באייפון…"
        let file = "RK-Motion-" + UUID().uuidString + ".mp4", output = LocalStore.file(file, project: p.id)
        operation = Task {
            guard await save() else {setBusy(false); return}
            do {
                let duration = try await engine.export(p, edit: snapshot, output: output) {[weak self] fraction, text in await self?.progress(fraction, text)}
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                current.exports.append(LocalExport(file: file, duration: duration)); project = current; movieURL = output
                if await save() {projectBytes = await persistence.bytes(current); message = "הסרט נוצר באייפון ומוכן לשמירה ושיתוף"}
            } catch is CancellationError {try? FileManager.default.removeItem(at: output); message = "הייצוא בוטל. העריכה נשמרה."}
            catch {try? FileManager.default.removeItem(at: output); message = error.localizedDescription}
            setBusy(false)
        }
    }
    func cancel() {operation?.cancel()}
    func pause() {
        scheduleSave(immediate: true)
        if busy && backgroundID == .invalid {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Finish local processing") {[weak self] in
                self?.operation?.cancel(); self?.endBackground()
            }
        }
    }
    func foreground() {if !busy {endBackground()}}
    private func endBackground() {if backgroundID != .invalid {UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid}}
    func reset() async {
        guard !busy, let p = project else {return}
        setBusy(true); saveTask?.cancel(); saveTask = nil
        do {
            try await persistence.deleteProject(p.id)
            projects.removeAll {$0.id == p.id}; project = nil; movieURL = nil; previewItem = nil; projectBytes = 0; edit = Edit(clips: []); suppressedEdit = edit
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
    func deleteExport(_ result: LocalExport) async {
        guard !busy, var p = project else {return}
        setBusy(true)
        guard await save() else {setBusy(false); return}
        p.edit = edit; p.exports.removeAll {$0.id == result.id}; revision += 1
        do {
            try await persistence.deleteExport(result, from: p, revision: revision)
            project = p; refreshLibrary(p)
            if movieURL?.lastPathComponent == result.file {movieURL = nil}
            projectBytes = await persistence.bytes(p); message = "הסרט שנוצר נמחק מהאפליקציה"
        } catch {message = error.localizedDescription}
        setBusy(false)
    }
    func preview() {
        guard !busy, let p = project, p.analyzed else {return}
        let snapshot = edit; setBusy(true); percent = 0
        operation = Task {
            guard await save() else {setBusy(false); return}
            do {previewItem = try await engine.preview(p, edit: snapshot); message = "תצוגה מקדימה של העריכה — ללא יצירת קובץ"}
            catch is CancellationError {message = "התצוגה המקדימה בוטלה"}
            catch {message = error.localizedDescription}
            setBusy(false)
        }
    }
    func saveToPhotos(_ file: URL) async {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {message = "אפשרו שמירה בתמונות בהגדרות האייפון"; return}
        do {try await PHPhotoLibrary.shared().performChanges {PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)}; message = "הסרט נשמר בתמונות"}
        catch {message = error.localizedDescription}
    }
}
