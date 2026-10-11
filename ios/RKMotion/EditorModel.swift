import Foundation
import Combine
import Photos

@MainActor final class EditorModel: ObservableObject {
    @Published var connected = Credentials.load() != nil
    @Published var projects: [Project] = []
    @Published var report: Report?
    @Published var edit = Edit(clips: [])
    @Published var exports: [Export] = []
    @Published var message = ""
    @Published var percent: Double = 0
    @Published var busy = false
    @Published var wholeVideo = false
    @Published var useMusic = false
    @Published var music: [Music] = []
    @Published var activeJob = UserDefaults.standard.string(forKey: "activeJob")
    @Published var undoAvailable = false
    @Published var redoAvailable = false
    private var revision = 0
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private var suppressedEdit: Edit?
    private var saveTask: Task<Void, Never>?
    private var saveInProgress = false
    private var polling: Task<Void, Never>?
    private var savedEdit: Edit?
    private var client: APIClient? {Credentials.load().map(APIClient.init)}

    func pair(_ link: String) async {
        do {
            let (pending, code) = try Connection.pairingLink(link)
            let paired: Paired = try await APIClient(pending).call("/api/pair", method: "POST", body: ["code": code])
            var connection = pending; connection.token = paired.token
            try Credentials.save(connection); connected = true
            message = "החיבור למק הושלם"
            await reconnect()
        } catch {message = error.localizedDescription}
    }
    func disconnect() {
        polling?.cancel(); saveTask?.cancel(); Transfers.shared.cancelAll()
        Credentials.clear(); connected = false; activeJob = nil; report = nil
        UserDefaults.standard.removeObject(forKey: "activeJob")
    }
    func reconnect() async {
        guard let client else {return}
        do {
            let _: Capabilities = try await client.call("/api/capabilities")
            let list: ProjectList = try await client.call("/api/projects"); projects = list.projects
            await Transfers.shared.resumeAll()
            if let job = activeJob, !Transfers.shared.records.values.contains(where: {$0.job == job && $0.kind == "video"}) {
                if UserDefaults.standard.string(forKey: "pendingAnalysis") == job {await analyze(job)}
                else {await openProject(job)}
            }
        } catch {message = error.localizedDescription}
    }
    func importVideo(_ file: URL) async {
        guard let client else {return}
        do {
            let prepared: Prepared = try await client.call("/api/prepare", method: "POST")
            setActive(prepared.job_id); report = nil; exports = []
            UserDefaults.standard.set(prepared.job_id, forKey: "pendingAnalysis")
            UserDefaults.standard.set(wholeVideo, forKey: "pendingWhole")
            try await Transfers.shared.start(file: file, job: prepared.job_id)
        } catch {message = error.localizedDescription}
    }
    func importMusic(_ file: URL) async {
        guard let job = activeJob else {return}
        do {try await Transfers.shared.start(file: file, job: job, kind: "music")}
        catch {message = error.localizedDescription}
    }
    func uploadFinished(job: String, kind: String) async {
        guard job == activeJob else {return}
        if kind == "video" {await analyze(job)}
        else if let client {
            do {let session: Session = try await client.call("/api/session/" + job); music = session.music; useMusic = !music.isEmpty}
            catch {message = error.localizedDescription}
        }
    }
    private func setActive(_ job: String) {activeJob = job; UserDefaults.standard.set(job, forKey: "activeJob")}
    func analyze(_ job: String) async {
        guard let client else {return}
        do {
            let headers = UserDefaults.standard.bool(forKey: "pendingWhole") ? ["X-Whole-Video": "1"] : [:]
            let started: Accepted = try await client.call("/api/analyse-batch/" + job, method: "POST", headers: headers)
            UserDefaults.standard.removeObject(forKey: "pendingAnalysis")
            follow(started.status_url, job: job, analysis: true)
        } catch {
            // A response may be lost after the Mac has started. Reconnect to
            // its existing status instead of starting a second analysis.
            do {
                let status: Status = try await client.call("/api/analyse-status/" + job)
                if status.state == "running" || status.state == "done" {
                    UserDefaults.standard.removeObject(forKey: "pendingAnalysis")
                    follow("/api/analyse-status/" + job, job: job, analysis: true)
                } else {message = error.localizedDescription}
            } catch {message = error.localizedDescription}
        }
    }
    func openProject(_ job: String) async {
        guard let client else {return}
        polling?.cancel(); setActive(job)
        do {
            let status: Status = try await client.call("/api/analyse-status/" + job)
            if status.state == "running" {follow("/api/analyse-status/" + job, job: job, analysis: true); return}
            guard let report = status.report else {throw AppError(message: status.message ?? "Retry the analysis on the Mac.")}
            self.report = report
            let session: Session = try await client.call("/api/session/" + job)
            revision = session.revision; exports = session.exports; music = session.music; useMusic = !music.isEmpty
            let backupKey = "edit-" + job
            if let data = UserDefaults.standard.data(forKey: backupKey),
               UserDefaults.standard.integer(forKey: backupKey + "-revision") == revision,
               let backup = try? JSONDecoder().decode(Edit.self, from: data) {edit = backup}
            else {edit = session.edit ?? Edit(clips: report.clips)}
            suppressedEdit = edit
            savedEdit = session.edit
            undoStack = []; redoStack = []; updateUndo()
            let exporting: Status? = try? await client.call("/api/export-status/" + job)
            if exporting?.state == "running" {follow("/api/export-status/" + job, job: job, analysis: false)}
            else {busy = false; message = "הפרויקט מוכן לעריכה"; if edit != savedEdit {await save()}}
        } catch {busy = false; message = error.localizedDescription}
    }
    func changed(from previous: Edit) {
        guard report != nil else {return}
        if let suppressed = suppressedEdit {suppressedEdit = nil; if suppressed == edit {return}}
        undoStack.append(previous); if undoStack.count > 40 {undoStack.removeFirst()}
        redoStack.removeAll(); updateUndo(); backup()
        saveTask?.cancel()
        saveTask = Task {try? await Task.sleep(for: .milliseconds(500)); if !Task.isCancelled {await save()}}
    }
    private func backup() {
        guard let job = activeJob, let data = try? JSONEncoder().encode(edit) else {return}
        UserDefaults.standard.set(data, forKey: "edit-" + job)
        UserDefaults.standard.set(revision, forKey: "edit-" + job + "-revision")
    }
    private func valid() -> Bool {
        guard let report else {return false}
        return edit.clips.allSatisfy {$0.start.isFinite && $0.end.isFinite && 0 <= $0.start && $0.start < $0.end && $0.end <= report.duration + 0.05}
    }
    func save() async {
        guard !saveInProgress, valid(), let client, let job = activeJob else {return}
        saveInProgress = true; defer {saveInProgress = false}
        let snapshot = edit
        do {
            let reply: Revision = try await client.call("/api/edit/" + job, method: "POST",
                body: ["edit": try snapshot.jsonObject(), "revision": revision])
            guard activeJob == job else {return}
            revision = reply.revision; savedEdit = snapshot; backup()
            if snapshot != edit {saveTask = Task {await Task.yield(); await self.save()}}
        } catch {message = "השמירה במק נכשלה; עותק נשמר באייפון. " + error.localizedDescription; backup()}
    }
    func undo() {guard let previous = undoStack.popLast() else {return}; redoStack.append(edit); edit = previous; suppressedEdit = previous; updateUndo(); backup(); Task {await save()}}
    func redo() {guard let next = redoStack.popLast() else {return}; undoStack.append(edit); edit = next; suppressedEdit = next; updateUndo(); backup(); Task {await save()}}
    private func updateUndo() {undoAvailable = !undoStack.isEmpty; redoAvailable = !redoStack.isEmpty}
    func exportMovie() async {
        guard !busy, valid(), let client, let job = activeJob else {message = "בדקו שזמני הקטעים נמצאים בתוך הסרטון"; return}
        let clips = edit.clips.filter {$0.selected != false}
        guard !clips.isEmpty else {message = "בחרו לפחות קטע אחד"; return}
        busy = true; await save()
        do {
            let s = edit.settings
            let body: [String: Any] = ["job_id": job, "clips": try clips.jsonObject(),
                "quality": s["quality"]?.string ?? "1080", "aspect": s["aspect"]?.string ?? "16:9",
                "speed": Double(s["speed"]?.string ?? "1") ?? 1,
                "transition": s["transition"]?.string ?? "cut",
                "transition_duration": Double(s["transitionDuration"]?.string ?? "0.5") ?? 0.5,
                "use_music": useMusic, "music_start": Double(s["musicStart"]?.string ?? "0") ?? 0,
                "music_volume": Double(s["musicVolume"]?.string ?? "0.65") ?? 0.65,
                "remove_original_audio": s["muteOriginal"]?.bool ?? false]
            let reply: Accepted = try await client.call("/api/export", method: "POST", body: body,
                headers: ["Idempotency-Key": UUID().uuidString])
            follow(reply.status_url, job: job, analysis: false)
        } catch {busy = false; message = error.localizedDescription}
    }
    func follow(_ path: String, job: String, analysis: Bool) {
        polling?.cancel(); busy = true
        polling = Task {
            do {
                while !Task.isCancelled {
                    guard let client, activeJob == job else {return}
                    let status: Status = try await client.call(path)
                    try Task.checkCancellation()
                    message = status.message ?? ""; percent = status.percent ?? 0
                    if status.state == "done" {
                        busy = false
                        if analysis {polling = nil; await openProject(job)}
                        else {let session: Session = try await client.call("/api/session/" + job); exports = session.exports}
                        return
                    }
                    if status.state == "error" {busy = false; return}
                    try await Task.sleep(for: .seconds(2))
                }
            } catch is CancellationError {} catch {busy = false; message = error.localizedDescription}
        }
    }
    func pause() {polling?.cancel(); backup(); Task {await save()}}
    func preview() {guard let job = activeJob else {return}; do {try Transfers.shared.download("/api/proxy/" + job, preview: true)} catch {message = error.localizedDescription}}
    func reset() async {
        guard let job = activeJob, let client else {return}
        do {
            let _: OK = try await client.call("/api/reset/" + job, method: "POST")
            polling?.cancel(); report = nil; activeJob = nil; edit = Edit(clips: []); exports = []
            UserDefaults.standard.removeObject(forKey: "activeJob"); UserDefaults.standard.removeObject(forKey: "edit-" + job)
            await reconnect()
        } catch {message = error.localizedDescription}
    }
    func saveToPhotos(_ file: URL) async {
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {message = "אפשרו שמירה בתמונות בהגדרות האייפון"; return}
        do {try await PHPhotoLibrary.shared().performChanges {PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)}; message = "הסרט נשמר בתמונות"}
        catch {message = error.localizedDescription}
    }
}
