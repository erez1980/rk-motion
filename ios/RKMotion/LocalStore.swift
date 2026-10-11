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
    static func save(_ project: LocalProject) throws {
        try FileManager.default.createDirectory(at: folder(project.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: file("project.json", project: project.id), options: .atomic)
    }
    static func load() -> [LocalProject] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap {url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
                  let p = try? JSONDecoder().decode(LocalProject.self, from: data),
                  UUID(uuidString: p.id) != nil, p.source == URL(fileURLWithPath: p.source).lastPathComponent,
                  FileManager.default.fileExists(atPath: file(p.source, project: p.id).path) else {return nil}
            return p
        }.sorted {$0.created > $1.created}
    }
    static func checkSpace(at source: URL) throws {
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try checkSpace(required: bytes + 256 * 1024 * 1024)
    }
    static func checkSpace(required: Int64) throws {
        let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
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
