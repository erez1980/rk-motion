import Foundation
import CoreTransferable
import UniformTypeIdentifiers

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) {received in
            let target = LocalStore.imports.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try LocalStore.checkSpace(at: received.file)
            try FileManager.default.copyItem(at: received.file, to: target)
            return PickedMovie(url: target)
        }
    }
}
enum LocalStore {
    static let root = directory("projects")
    static let imports = directory("imports")
    static func directory(_ name: String) -> URL {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let path = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    static func folder(_ id: String) -> URL {root.appendingPathComponent(id, isDirectory: true)}
    static func file(_ name: String, project: String) -> URL {folder(project).appendingPathComponent(name)}
    @discardableResult static func save(_ project: LocalProject, writeScores: Bool = true, scoresFile: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: folder(project.id), withIntermediateDirectories: true)
        // Analysis data is immutable between scans; don't rewrite it on every trim.
        let scoreName = writeScores ? "scores-" + UUID().uuidString + ".json" : (scoresFile ?? project.scoresFile ?? "scores.json")
        if writeScores {
            try JSONEncoder().encode(project.scores).write(to: file(scoreName, project: project.id), options: .atomic)
        }
        // Commit the reference atomically after writing a new immutable score
        // file. A crash between writes leaves the old project valid.
        var metadata = project; metadata.scores = []; metadata.scoresFile = scoreName
        try JSONEncoder().encode(metadata).write(to: file("project.json", project: project.id), options: .atomic)
        return scoreName
    }
    static func load() -> [LocalProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap {url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
                  var p = try? JSONDecoder().decode(LocalProject.self, from: data),
                  UUID(uuidString: p.id) != nil, p.source == URL(fileURLWithPath: p.source).lastPathComponent,
                  FileManager.default.fileExists(atPath: file(p.source, project: p.id).path) else {return nil}
            let scoreName = p.scoresFile ?? "scores.json"
            if scoreName == URL(fileURLWithPath: scoreName).lastPathComponent,
               let scoreData = try? Data(contentsOf: url.appendingPathComponent(scoreName)),
               let scores = try? JSONDecoder().decode([Double].self, from: scoreData) {p.scores = scores}
            return p
        }.sorted {$0.created > $1.created}
    }
    static func bytes(in folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {return 0}
        return items.compactMap {$0 as? URL}.reduce(Int64(0)) {sum, url in
            guard let value = try? url.resourceValues(forKeys: keys), value.isRegularFile == true else {return sum}
            return sum + Int64(value.fileSize ?? 0)
        }
    }
    /// Called explicitly while the editor is idle, never during a live import.
    /// Retains all originals/music and all exports referenced by valid projects.
    static func cleanTemporaryFiles() throws -> Int64 {
        var reclaimed: Int64 = 0
        func remove(_ url: URL) throws {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try FileManager.default.removeItem(at: url); reclaimed += size
        }
        for url in try FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil) {try remove(url)}
        for p in load() {
            let retained = Set(p.exports.map { $0.file })
            for url in try FileManager.default.contentsOfDirectory(at: folder(p.id), includingPropertiesForKeys: nil)
                where (url.lastPathComponent.hasPrefix("RK-Motion-") && url.pathExtension == "mp4" && !retained.contains(url.lastPathComponent)) ||
                      (url.lastPathComponent.hasPrefix("scores-") && url.pathExtension == "json" && url.lastPathComponent != p.scoresFile) {
                try remove(url)
            }
        }
        return reclaimed
    }
    static func checkSpace(at source: URL) throws {
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try checkSpace(required: bytes + 256 * 1024 * 1024)
    }
    static func checkSpace(required: Int64) throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let fallback = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let available = values.volumeAvailableCapacityForImportantUsage ?? fallback
        guard available >= required else {throw AppError(message: "אין מספיק מקום פנוי באייפון. פנו מקום ונסו שוב.")}
    }
    static func importFile(_ source: URL, project: String, prefix: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer {if access {source.stopAccessingSecurityScopedResource()}}
            try FileManager.default.createDirectory(at: folder(project), withIntermediateDirectories: true)
            let name = prefix + "-" + UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
            let target = file(name, project: project)
            if source.deletingLastPathComponent() == imports {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try checkSpace(at: source)
                try FileManager.default.copyItem(at: source, to: target)
            }
            return name
        }.value
    }
}
