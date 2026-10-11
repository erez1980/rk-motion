import Foundation
import Combine
import UniformTypeIdentifiers
import CoreTransferable

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = TransferStore.directory("imports")
            let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}

enum TransferStore {
    static func directory(_ name: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static let recordsURL = directory("state").appendingPathComponent("uploads.json")
}

struct UploadRecord: Codable, Identifiable {
    var id: String
    var job: String
    var file: URL
    var size: Int64
    var offset: Int64
    var kind: String
}

extension Notification.Name {
    static let rkUploadFinished = Notification.Name("rkUploadFinished")
}

final class Transfers: PinnedDelegate, ObservableObject, URLSessionDataDelegate, URLSessionDownloadDelegate {
    static let shared = Transfers()
    static let sessionID = "com.rkmotion.companion.transfers.v1"
    @Published var records: [String: UploadRecord] = [:]
    @Published var progress: Double = 0
    @Published var message = ""
    @Published var previewURL: URL?
    @Published var movieURL: URL?
    var backgroundCompletion: (() -> Void)?
    private var responseBodies: [Int: Data] = [:]
    private var scheduling = Set<String>()
    private lazy var background: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 24 * 3600
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue.main)
    }()

    private override init(connection: Connection? = nil) {
        super.init(connection: connection)
        if let data = try? Data(contentsOf: TransferStore.recordsURL),
           let saved = try? JSONDecoder().decode([String: UploadRecord].self, from: data) {records = saved}
        if let path = UserDefaults.standard.string(forKey: "moviePath"), FileManager.default.fileExists(atPath: path) {movieURL = URL(fileURLWithPath: path)}
    }
    private func persist() {
        do {try JSONEncoder().encode(records).write(to: TransferStore.recordsURL, options: .atomic)}
        catch {message = "לא ניתן לשמור את מצב ההעלאה: " + error.localizedDescription}
    }
    @MainActor func start(file: URL, job: String, kind: String = "video") async throws {
        guard let connection = Credentials.load() else {throw AppError(message: "Connect to the Mac first.")}
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        let reply: UploadStart = try await APIClient(connection).call("/api/uploads/" + job, method: "POST",
            body: ["name": file.lastPathComponent, "size": size, "kind": kind])
        let record = UploadRecord(id: reply.upload_id, job: job, file: file, size: Int64(size), offset: 0, kind: kind)
        records[record.id] = record; persist()
        await schedule(record.id)
    }
    @MainActor func resumeAll() async {
        _ = background
        for id in Array(records.keys) {await schedule(id)}
    }
    @MainActor private func schedule(_ id: String) async {
        guard !scheduling.contains(id), var record = records[id], let connection = Credentials.load() else {return}
        scheduling.insert(id)
        defer {scheduling.remove(id)}
        let tasks = await background.allTasks
        if tasks.contains(where: {$0.taskDescription?.hasPrefix("upload|" + id + "|") == true}) {return}
        do {
            let remote: UploadStatus = try await APIClient(connection).call("/api/uploads/\(record.job)/\(id)")
            record.offset = remote.offset; records[id] = record; persist()
            if remote.complete {finish(record); return}
            let handle = try FileHandle(forReadingFrom: record.file)
            defer {try? handle.close()}
            try handle.seek(toOffset: UInt64(remote.offset))
            guard let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty else {throw AppError(message: "The local video is missing. Choose it again.")}
            let chunk = TransferStore.directory("chunks").appendingPathComponent("\(id)-\(remote.offset).bin")
            try data.write(to: chunk, options: .atomic)
            var request = try connection.request("/api/chunk/\(record.job)/\(id)", method: "POST")
            request.setValue(String(remote.offset), forHTTPHeaderField: "Upload-Offset")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = background.uploadTask(with: request, fromFile: chunk)
            task.taskDescription = "upload|\(id)|\(remote.offset)|\(chunk.lastPathComponent)"
            message = "מעלה למק — ניתן להמשיך לאחר ניתוק"; task.resume()
        } catch {message = error.localizedDescription + " · פתחו שוב את האפליקציה כדי להמשיך."}
    }
    private func finish(_ record: UploadRecord) {
        records.removeValue(forKey: record.id); persist(); progress = 1
        try? FileManager.default.removeItem(at: record.file)
        NotificationCenter.default.post(name: .rkUploadFinished, object: nil, userInfo: ["job": record.job, "kind": record.kind])
    }
    func download(_ path: String, preview: Bool = false) throws {
        guard let connection = Credentials.load() else {throw AppError(message: "Connect first.")}
        let task = background.downloadTask(with: try connection.request(path))
        task.taskDescription = "download|" + (preview ? "preview" : "movie") + "|" + UUID().uuidString
        message = preview ? "מורידה תצוגה מקדימה…" : "מורידה את הסרט לקובץ…"
        task.resume()
    }
    func cancelAll() {
        background.getAllTasks {tasks in tasks.forEach {$0.cancel()}}
        records.removeAll(); persist()
        message = "ההעברות בוטלו"
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var body = responseBodies[dataTask.taskIdentifier] ?? Data()
        if body.count < 65536 {body.append(data)}
        responseBodies[dataTask.taskIdentifier] = body
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let parts = task.taskDescription?.split(separator: "|").map(String.init) ?? []
        if parts.count == 4, let record = records[parts[1]], let offset = Int64(parts[2]) {
            progress = Double(offset + totalBytesSent) / Double(max(1, record.size))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)}
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {message = "ההורדה נכשלה"; return}
        let parts = downloadTask.taskDescription?.split(separator: "|").map(String.init) ?? []
        guard parts.count == 3 else {return}
        do {
            let target = TransferStore.directory("movies").appendingPathComponent(parts[2]).appendingPathExtension("mp4")
            try FileManager.default.moveItem(at: location, to: target)
            if parts[1] == "preview" {
                if let old = previewURL {try? FileManager.default.removeItem(at: old)}
                previewURL = target
            } else {movieURL = target; UserDefaults.standard.set(target.path, forKey: "moviePath")}
            progress = 1; message = "הקובץ מוכן במכשיר"
        } catch {message = error.localizedDescription}
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let parts = task.taskDescription?.split(separator: "|").map(String.init) ?? []
        guard parts.count == 4, parts[0] == "upload" else {
            if let error {message = error.localizedDescription}; return
        }
        try? FileManager.default.removeItem(at: TransferStore.directory("chunks").appendingPathComponent(parts[3]))
        guard error == nil, let response = task.response as? HTTPURLResponse, response.statusCode == 200,
              let state = try? JSONDecoder().decode(UploadStatus.self, from: data), var record = records[parts[1]] else {
            message = error?.localizedDescription ?? "ההעלאה נעצרה. פתחו שוב את האפליקציה כדי להמשיך."
            return
        }
        record.offset = state.offset; records[record.id] = record; persist()
        if state.complete {finish(record)} else {Task {@MainActor in await self.schedule(record.id)}}
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = backgroundCompletion; backgroundCompletion = nil; done?()
    }
}
