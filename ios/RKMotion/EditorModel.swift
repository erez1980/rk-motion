import Foundation
import AVFoundation
import Combine
import Photos
import UIKit

@MainActor final class EditorModel: ObservableObject {
    @Published var projects = LocalStore.load()
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
    private let engine = LocalEngine()
    private var operation: Task<Void, Never>?
    private var suppressedEdit: Edit?
    private var undoStack: [Edit] = [], redoStack: [Edit] = []
    private var backgroundID = UIBackgroundTaskIdentifier.invalid
    var sourceURL: URL? {project.map {LocalStore.file($0.source, project: $0.id)}}

    func restore() {
        guard project == nil, let id = UserDefaults.standard.string(forKey: "localProject"), let saved = projects.first(where: {$0.id == id}) else {return}
        open(saved)
    }
    func open(_ value: LocalProject) {
        guard !busy else {return}
        save(); project = value; edit = value.edit; suppressedEdit = edit
        undoStack = []; redoStack = []; updateUndo()
        movieURL = value.exports.last.map {LocalStore.file($0.file, project: value.id)}
        UserDefaults.standard.set(value.id, forKey: "localProject")
        message = value.analyzed ? "הפרויקט נשמר באייפון" : "הסרטון נשמר. אפשר לחדש את הניתוח."
    }
    func changed(from previous: Edit) {
        guard project != nil else {return}
        if let suppressed = suppressedEdit {suppressedEdit = nil; if suppressed == edit {return}}
        undoStack.append(previous); if undoStack.count > 40 {undoStack.removeFirst()}
        redoStack = []; updateUndo(); save()
    }
    func save() {
        guard var p = project else {return}
        p.edit = edit
        do {try LocalStore.save(p); project = p; refreshLibrary(p)}
        catch {message = "שמירת הפרויקט נכשלה: " + error.localizedDescription}
    }
    private func refreshLibrary(_ p: LocalProject) {projects.removeAll {$0.id == p.id}; projects.insert(p, at: 0)}
    private func setBusy(_ value: Bool) {
        busy = value; UIApplication.shared.isIdleTimerDisabled = value
        if !value {operation = nil; endBackground()}
    }
    func importVideo(_ file: URL) async {
        guard !busy else {message = "המתינו לסיום הפעולה הנוכחית"; return}
        save(); setBusy(true); percent = 0; message = "מעתיקה את הסרטון לאחסון המקומי…"
        var p = LocalProject(name: file.lastPathComponent, source: "")
        do {
            p.source = try await LocalStore.importFile(file, project: p.id, prefix: "source")
            try LocalStore.save(p); project = p; edit = p.edit; suppressedEdit = edit; movieURL = nil
            undoStack = []; redoStack = []; updateUndo(); refreshLibrary(p)
            UserDefaults.standard.set(p.id, forKey: "localProject")
            setBusy(false); analyze()
        } catch {setBusy(false); message = error.localizedDescription; try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
    }
    func analyze() {
        guard !busy, let p = project else {return}
        setBusy(true); percent = 0; message = "מנתחת באייפון…"
        let whole = wholeVideo
        operation = Task {
            do {
                let (duration, scores, clips) = try await engine.analyze(LocalStore.file(p.source, project: p.id), whole: whole) {[weak self] fraction, text in
                    await self?.progress(fraction, text)
                }
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                current.duration = duration; current.scores = scores; current.analyzed = true
                project = current; edit.clips = clips; suppressedEdit = edit; undoStack = []; redoStack = []; updateUndo(); save()
                message = clips.isEmpty ? "לא זוהו קטעי פעילות. שנו רגישות או הוסיפו קטע ידני." : "הניתוח הושלם — כל העיבוד נעשה באייפון"
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
        changed(from: previous); suppressedEdit = edit
    }
    func undo() {guard let previous = undoStack.popLast() else {return}; redoStack.append(edit); edit = previous; suppressedEdit = previous; updateUndo(); save()}
    func redo() {guard let next = redoStack.popLast() else {return}; undoStack.append(edit); edit = next; suppressedEdit = next; updateUndo(); save()}
    private func updateUndo() {undoAvailable = !undoStack.isEmpty; redoAvailable = !redoStack.isEmpty}
    func importMusic(_ file: URL) async {
        guard !busy, var p = project else {return}
        setBusy(true); message = "מוסיפה מוזיקה מקומית…"
        var imported: String?
        do {
            let name = try await LocalStore.importFile(file, project: p.id, prefix: "music"); imported = name
            let url = LocalStore.file(name, project: p.id)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {throw AppError(message: "בחרו קובץ שמע תקין.")}
            p.music.append(LocalMusic(file: name, name: file.lastPathComponent, duration: duration))
            project = p; save(); message = "המוזיקה נשמרה באייפון"
        } catch {if let imported {try? FileManager.default.removeItem(at: LocalStore.file(imported, project: p.id))}; message = error.localizedDescription}
        setBusy(false)
    }
    func removeMusic(_ id: String) {
        guard !busy, var p = project, let song = p.music.first(where: {$0.id == id}) else {return}
        p.music.removeAll {$0.id == id}; project = p; save()
        try? FileManager.default.removeItem(at: LocalStore.file(song.file, project: p.id))
    }
    func exportMovie() {
        guard !busy, let p = project, p.analyzed else {return}
        save(); let snapshot = edit
        setBusy(true); percent = 0; message = "מייצאת באייפון…"
        let file = "RK-Motion-" + UUID().uuidString + ".mp4", output = LocalStore.file(file, project: p.id)
        operation = Task {
            do {
                let duration = try await engine.export(p, edit: snapshot, output: output) {[weak self] fraction, text in await self?.progress(fraction, text)}
                try Task.checkCancellation()
                guard var current = project, current.id == p.id else {return}
                current.exports.append(LocalExport(file: file, duration: duration)); project = current; movieURL = output; save()
                message = "הסרט נוצר באייפון ומוכן לשמירה ושיתוף"
            } catch is CancellationError {try? FileManager.default.removeItem(at: output); message = "הייצוא בוטל. העריכה נשמרה."}
            catch {try? FileManager.default.removeItem(at: output); message = error.localizedDescription}
            setBusy(false)
        }
    }
    func cancel() {operation?.cancel()}
    func pause() {
        save()
        if busy && backgroundID == .invalid {
            backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Finish local processing") {[weak self] in
                self?.operation?.cancel(); self?.endBackground()
            }
        }
    }
    func foreground() {endBackground()}
    private func endBackground() {if backgroundID != .invalid {UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid}}
    func reset() {
        guard !busy, let p = project else {return}
        do {
            try FileManager.default.removeItem(at: LocalStore.folder(p.id))
            projects.removeAll {$0.id == p.id}; project = nil; movieURL = nil; edit = Edit(clips: []); suppressedEdit = edit
            UserDefaults.standard.removeObject(forKey: "localProject"); message = "הפרויקט נמחק מהאייפון"
        } catch {message = error.localizedDescription}
    }
    func saveToPhotos(_ file: URL) async {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {message = "אפשרו שמירה בתמונות בהגדרות האייפון"; return}
        do {try await PHPhotoLibrary.shared().performChanges {PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)}; message = "הסרט נשמר בתמונות"}
        catch {message = error.localizedDescription}
    }
}
