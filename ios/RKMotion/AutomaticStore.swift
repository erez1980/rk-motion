import Foundation
import CryptoKit
import AVFoundation

struct AutomaticRun: Codable, Equatable {
    var schema = 1
    var sourceFiles: [String]
    var style: AutomaticStyle
    var events: [AutomaticEvent]
    var review: AutomaticDirector.Review
    var edit: Edit
    var output: String?
    var completed = false
    var date = Date()
}

/// Versioned sidecars leave the existing project schema readable by earlier
/// versions. Save the export receipt only after media validation and persistence.
enum AutomaticStore {
    struct Version: Codable, Identifiable, Equatable {
        var id = UUID().uuidString
        var date = Date()
        var style: AutomaticStyle
        var edit: Edit
        var output: String?
    }
    struct Readiness: Codable {
        var sourcesPresent: Bool
        var musicPresent: Bool
        var availableBytes: Int64
        var sourceBytes: Int64
        var sufficientSpace: Bool {availableBytes > max(512 * 1024 * 1024, min(sourceBytes, 4 * 1024 * 1024 * 1024))}
        var ready: Bool {sourcesPresent && musicPresent && sufficientSpace}
    }
    static func save<T: Encodable>(_ value: T, name: String, project: String) throws {
        try JSONEncoder().encode(value).write(to: LocalStore.file(name, project: project), options: .atomic)
    }
    static func read<T: Decodable>(_ type: T.Type, name: String, project: String) -> T? {
        guard let data = try? Data(contentsOf: LocalStore.file(name, project: project)) else {return nil}
        return try? JSONDecoder().decode(type, from: data)
    }
    static func versions(_ project: String) -> [Version] {read([Version].self, name: "automatic-versions.json", project: project) ?? []}
    static func checkpoint(_ edit: Edit, style: AutomaticStyle, project: String, output: String? = nil) throws {
        var saved = versions(project)
        saved.append(Version(style: style, edit: edit, output: output))
        try save(Array(saved.suffix(20)), name: "automatic-versions.json", project: project)
    }
    static func readiness(_ project: LocalProject) -> Readiness {
        let present = project.files.allSatisfy {FileManager.default.fileExists(atPath: LocalStore.file($0, project: project.id).path)}
        let music = project.music.allSatisfy {FileManager.default.fileExists(atPath: LocalStore.file($0.file, project: project.id).path)}
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: LocalStore.folder(project.id).path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let bytes = project.files.reduce(Int64(0)) {$0 + Int64((try? LocalStore.file($1, project: project.id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)}
        return Readiness(sourcesPresent: present, musicPresent: music, availableBytes: available, sourceBytes: bytes)
    }
    static func digest(_ file: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer {try? handle.close()}
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes); await Task.yield()
        }
        return hash.finalize().map {String(format: "%02x", $0)}.joined()
    }
    /// A flat, self-contained package with sources, music, plan and hashes.
    /// No symlinks, absolute paths or external references are published.
    static func archive(_ project: LocalProject, edit: Edit) async throws -> URL {
        // Use the restore limits before copying large sources, then check the
        // complete inventory (including generated metadata) before publishing.
        func checkedBytes(_ files: [URL], extraEntries: Int = 0) throws -> Int64 {
            guard files.count + extraEntries <= AutomaticPackage.maximumEntries else {throw CocoaError(.fileReadCorruptFile)}
            var total: UInt64 = 0
            for file in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size >= 0,
                      AutomaticPackage.permits(name: file.lastPathComponent, bytes: UInt64(size)),
                      total <= AutomaticPackage.maximumBytes - UInt64(size) else {throw CocoaError(.fileReadCorruptFile)}
                total += UInt64(size)
            }
            return Int64(total)
        }
        let parent = LocalStore.folder(project.id).appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: stage)}
        let names = Set(project.files + project.music.map(\.file) + [LocalStore.signalsName, "automatic-run.json", "automatic-versions.json", "automatic-insights.json", "automatic-source-notes.txt"])
        let present = names.map {LocalStore.file($0, project: project.id)}.filter {FileManager.default.fileExists(atPath: $0.path)}
        let total = try checkedBytes(present, extraEntries: 3)
        try LocalStore.checkSpace(required: total * 2 + 256 * 1024 * 1024)
        var hashes: [String: String] = [:]
        for name in names.sorted() {
            guard name == URL(fileURLWithPath: name).lastPathComponent else {throw CocoaError(.fileReadInvalidFileName)}
            let source = LocalStore.file(name, project: project.id)
            guard FileManager.default.fileExists(atPath: source.path) else {
                if project.files.contains(name) || project.music.contains(where: {$0.file == name}) {throw CocoaError(.fileNoSuchFile)}
                continue
            }
            let target = stage.appendingPathComponent(name)
            try await LocalStore.copy(source, to: target)
            hashes[name] = try await digest(target)
        }
        var snapshot = project
        snapshot.edit = edit; snapshot.exports = []; snapshot.scoresFile = "scores.json"
        try JSONEncoder().encode(snapshot.scores).write(to: stage.appendingPathComponent("scores.json"), options: .atomic)
        snapshot.scores = []
        try JSONEncoder().encode(snapshot).write(to: stage.appendingPathComponent("project.json"), options: .atomic)
        hashes["scores.json"] = try await digest(stage.appendingPathComponent("scores.json"))
        hashes["project.json"] = try await digest(stage.appendingPathComponent("project.json"))
        try JSONEncoder().encode(hashes).write(to: stage.appendingPathComponent("checksums.json"), options: .atomic)
        _ = try checkedBytes(FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil))
        try Task.checkCancellation()
        let output = parent.appendingPathComponent("RK-Project-\(UUID().uuidString).zip")
        var failure: NSError?, copyingError: Error?
        NSFileCoordinator().coordinate(readingItemAt: stage, options: .forUploading, error: &failure) {compressed in
            do {try FileManager.default.copyItem(at: compressed, to: output)} catch {copyingError = error}
        }
        if let failure {throw failure}; if let copyingError {throw copyingError}
        do {try Task.checkCancellation()} catch {try? FileManager.default.removeItem(at: output); throw error}
        guard FileManager.default.fileExists(atPath: output.path) else {throw CocoaError(.fileWriteUnknown)}
        return output
    }
    static func validateMovie(_ output: URL, expected: Double) async throws {
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty, duration.isFinite, duration > 0, abs(duration - expected) <= max(0.2, expected / 100) else {throw CocoaError(.fileReadCorruptFile)}
    }
}
