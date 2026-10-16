import Foundation
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) {received in
            let target = LocalStore.imports.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try LocalStore.checkSpace(at: received.file)
            try await LocalStore.copy(received.file, to: target)
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
    static let signalsName = "signals.json"
    /// The scan's per-second signals, kept so another content kind can be
    /// scored without scanning again.
    static func writeSignals(_ signals: Signals, project: String) throws {
        try JSONEncoder().encode(signals).write(to: file(signalsName, project: project), options: .atomic)
    }
    static func readSignals(project: String) -> Signals? {
        guard let data = try? Data(contentsOf: file(signalsName, project: project)) else {return nil}
        return try? JSONDecoder().decode(Signals.self, from: data)
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
    /// Anything that can still become a project is rescued first, so what is
    /// removed from `imports` and from folders without a project is only what
    /// could not be played: pieces of an interrupted copy.
    static func cleanTemporaryFiles() async throws -> Int64 {
        _ = await recoverImports()
        var reclaimed: Int64 = 0
        func remove(_ url: URL) throws {
            reclaimed += bytes(in: url) + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try FileManager.default.removeItem(at: url)
        }
        for url in try FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil) {try remove(url)}
        let projects = load()
        let valid = Set(projects.map(\.id))
        // Only folders that never got a project: an import's own pieces.
        for folder in projectFolders() where !valid.contains(folder.lastPathComponent)
            && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) {try remove(folder)}
        for p in projects {
            let retained = Set(p.exports.map { $0.file })
            for url in try FileManager.default.contentsOfDirectory(at: folder(p.id), includingPropertiesForKeys: nil)
                where (url.lastPathComponent.hasPrefix("RK-Motion-") && url.pathExtension == "mp4" && !retained.contains(url.lastPathComponent)) ||
                      (url.lastPathComponent.hasPrefix("scores-") && url.pathExtension == "json" && url.lastPathComponent != p.scoresFile) ||
                      url.pathExtension == "part" || url.lastPathComponent == manifestName {
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
    static func importFile(_ source: URL, project: String, prefix: String, named: String? = nil, progress: (@Sendable (Double) async -> Void)? = nil) async throws -> String {
        let access = source.startAccessingSecurityScopedResource()
        defer {if access {source.stopAccessingSecurityScopedResource()}}
        try FileManager.default.createDirectory(at: folder(project), withIntermediateDirectories: true)
        let name = named ?? prefix + "-" + UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        let target = file(name, project: project)
        if source.deletingLastPathComponent() == imports {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try checkSpace(at: source)
            try await copy(source, to: target, progress: progress)
        }
        return name
    }

    // MARK: Copying and interrupted imports

    /// Bytes per piece of a copy; cancellation is checked between pieces.
    nonisolated(unsafe) static var copyChunk = 8 << 20
    /// Tests hold a copy here, after its first piece, to cancel it mid-way.
    nonisolated(unsafe) static var copyObserver: (@Sendable (Int64) async -> Void)?
    /// Copies in pieces into `target.part`, renamed into place only when
    /// whole. Cancelling stops between pieces and removes the partial file.
    static func copy(_ source: URL, to target: URL, progress: (@Sendable (Double) async -> Void)? = nil) async throws {
        let partial = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {throw AppError(message: "לא ניתן לשמור את הסרטון באייפון.")}
        do {
            let reader = try FileHandle(forReadingFrom: source), writer = try FileHandle(forWritingTo: partial)
            defer {try? reader.close(); try? writer.close()}
            let total = max(1, Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1))
            var copied: Int64 = 0
            while true {
                try Task.checkCancellation()
                let piece = try autoreleasepool {try reader.read(upToCount: copyChunk)} ?? Data()
                if piece.isEmpty {break}
                try writer.write(contentsOf: piece); copied += Int64(piece.count)
                await progress?(min(1, Double(copied) / Double(total)))
                await copyObserver?(copied)
            }
            try writer.synchronize()
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? FileManager.default.removeItem(at: partial); throw error
        }
    }
    /// Written into a new project's folder before its video is copied, and
    /// removed once the project is saved. Finding one later means the import
    /// was interrupted.
    struct ImportManifest: Codable {
        var name: String
        var source: String
        var bytes: Int64
        var wholeVideo: Bool
        var started = Date()
    }
    static let manifestName = "import.json"
    static func writeManifest(_ manifest: ImportManifest, project: String) throws {
        try FileManager.default.createDirectory(at: folder(project), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: file(manifestName, project: project), options: .atomic)
    }
    static func finishImport(project: String) {try? FileManager.default.removeItem(at: file(manifestName, project: project))}
    /// Removes what one live import made: its manifest and its own partial
    /// copy. The rider's original is never in this folder.
    static func abandonImport(project: String) {try? FileManager.default.removeItem(at: folder(project))}
    static func projectFolders() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.filter {(try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && UUID(uuidString: $0.lastPathComponent) != nil}
    }
    static func isPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video) else {return false}
        return !tracks.isEmpty
    }
    struct Recovery {
        var rescued: [LocalProject] = []
        /// Pieces that could not become a project. Kept until the rider
        /// chooses to clean up, never removed on their own.
        var fragmentBytes: Int64 = 0
    }
    /// Turns what an interrupted import left behind back into projects: a
    /// folder whose whole video was copied but whose project was never saved
    /// (from a manifest, or an older version's bare source file), and a movie
    /// the photo picker had already handed over. Nothing is deleted here.
    static func recoverImports() async -> Recovery {
        var report = Recovery()
        let valid = Set(load().map(\.id))
        for folder in projectFolders() {
            let id = folder.lastPathComponent
            if valid.contains(id) {finishImport(project: id); continue}
            // A saved project that no longer loads is not an import; leave it.
            guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {continue}
            let manifest = (try? Data(contentsOf: folder.appendingPathComponent(manifestName))).flatMap {try? JSONDecoder().decode(ImportManifest.self, from: $0)}
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let candidates = ([manifest?.source].compactMap {$0} + files.filter {$0.hasPrefix("source-") && !$0.hasSuffix(".part")}.sorted())
                .filter {files.contains($0)}
            var rescued = false
            for name in candidates where await isPlayableVideo(folder.appendingPathComponent(name)) {
                var p = LocalProject(name: manifest?.name ?? NSLocalizedString("סרטון ששוחזר", comment: "Name of a project rescued from an interrupted import"), source: name)
                p.id = id; p.wholeVideo = manifest?.wholeVideo ?? false
                if (try? save(p)) != nil {finishImport(project: id); report.rescued.append(p); rescued = true}
                break
            }
            if !rescued {report.fragmentBytes += bytes(in: folder)}
        }
        let picked = (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? []
        for url in picked.sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) {
            guard url.pathExtension != "part", await isPlayableVideo(url) else {
                report.fragmentBytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                continue
            }
            var p = LocalProject(name: NSLocalizedString("סרטון ששוחזר", comment: "Name of a project rescued from an interrupted import"), source: "")
            do {
                p.source = try await importFile(url, project: p.id, prefix: "source")
                try save(p); report.rescued.append(p)
            } catch {
                // Put the movie back where it was rather than lose it.
                if !p.source.isEmpty {try? FileManager.default.moveItem(at: file(p.source, project: p.id), to: url)}
                try? FileManager.default.removeItem(at: folder(p.id))
            }
        }
        return report
    }
}
