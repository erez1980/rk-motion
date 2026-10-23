import Foundation
import ZIPFoundation

/// Restore to a fresh UUID only after full verification. Imported packages
/// cannot overwrite another project, escape staging or install symlinks.
enum AutomaticPackage {
    static let maximumBytes: UInt64 = 32 * 1024 * 1024 * 1024
    static func safeName(_ path: String) -> String? {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {return nil}
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 2, !pieces.contains(where: {$0.isEmpty || $0 == "." || $0 == ".."}) else {return nil}
        return pieces.last.map(String.init)
    }
    static func restore(_ file: URL) async throws -> LocalProject {
        let access = file.startAccessingSecurityScopedResource()
        defer {if access {file.stopAccessingSecurityScopedResource()}}
        let archive = try Archive(url: file, accessMode: .read)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: stage)}
        let entries = archive.filter {$0.type != .directory}
        guard !entries.isEmpty, entries.count <= 512 else {throw CocoaError(.fileReadCorruptFile)}
        var total: UInt64 = 0, names = Set<String>()
        for entry in entries {
            guard entry.type == .file, let name = safeName(entry.path), names.insert(name).inserted,
                  entry.uncompressedSize <= maximumBytes, total <= maximumBytes - entry.uncompressedSize else {throw CocoaError(.fileReadCorruptFile)}
            if name.hasSuffix(".json"), entry.uncompressedSize > 32 * 1024 * 1024 {throw CocoaError(.fileReadCorruptFile)}
            if name.hasSuffix(".txt"), entry.uncompressedSize > 2 * 1024 * 1024 {throw CocoaError(.fileReadCorruptFile)}
            total += entry.uncompressedSize
        }
        try LocalStore.checkSpace(required: Int64(total) + 256 * 1024 * 1024)
        for entry in entries {
            try Task.checkCancellation()
            let name = safeName(entry.path)!
            let target = stage.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {throw CocoaError(.fileWriteUnknown)}
            let handle = try FileHandle(forWritingTo: target)
            defer {try? handle.close()}
            var written: UInt64 = 0
            let checksum = try archive.extract(entry, bufferSize: 1024 * 1024, skipCRC32: false) {chunk in
                try Task.checkCancellation()
                written += UInt64(chunk.count)
                guard written <= entry.uncompressedSize else {throw CocoaError(.fileReadCorruptFile)}
                try handle.write(contentsOf: chunk)
            }
            guard written == entry.uncompressedSize, checksum == entry.checksum else {throw CocoaError(.fileReadCorruptFile)}
            await Task.yield()
        }
        func metadata(_ name: String) throws -> Data {
            let url = stage.appendingPathComponent(name)
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024 else {throw CocoaError(.fileReadCorruptFile)}
            return try Data(contentsOf: url)
        }
        let checksums = try JSONDecoder().decode([String: String].self, from: metadata("checksums.json"))
        guard checksums.count <= 511, names.subtracting(["checksums.json"]) == Set(checksums.keys),
              checksums.keys.allSatisfy({safeName($0) == $0}) else {throw CocoaError(.fileReadCorruptFile)}
        for (name, expected) in checksums {
            let actual = try await AutomaticStore.digest(stage.appendingPathComponent(name))
            guard actual == expected else {throw CocoaError(.fileReadCorruptFile)}
        }
        var project = try JSONDecoder().decode(LocalProject.self, from: metadata("project.json"))
        guard !project.files.isEmpty, project.parts?.isEmpty != true,
              project.parts.map({$0.first?.file == project.source}) ?? true,
              project.files.allSatisfy({names.contains($0) && safeName($0) == $0}),
              project.music.allSatisfy({names.contains($0.file) && safeName($0.file) == $0.file}),
              project.duration.isFinite, 0...86400 ~= project.duration else {throw CocoaError(.fileReadCorruptFile)}
        if let parts = project.parts {
            var cursor = 0.0
            for part in parts {
                guard part.start.isFinite, part.duration.isFinite, part.duration > 0,
                      abs(part.start - cursor) < 0.01, part.end.isFinite, part.end <= 86400 else {throw CocoaError(.fileReadCorruptFile)}
                cursor = part.end
            }
            if project.analyzed, abs(cursor - project.duration) > 0.1 {throw CocoaError(.fileReadCorruptFile)}
        }
        project.id = UUID().uuidString
        project.exports = []
        project.scores = try JSONDecoder().decode([Double].self, from: metadata("scores.json"))
        guard project.scores.count <= 86400, project.scores.allSatisfy(\.isFinite) else {throw CocoaError(.fileReadCorruptFile)}
        // Packages deliberately omit rendered exports. Keep their analysis, but
        // never restore a receipt which says a missing rendered file is ready.
        let runFile = stage.appendingPathComponent("automatic-run.json")
        if let data = try? Data(contentsOf: runFile), var run = try? JSONDecoder().decode(AutomaticRun.self, from: data) {
            run.output = nil; run.completed = false
            try JSONEncoder().encode(run).write(to: runFile, options: .atomic)
        }
        try Task.checkCancellation()
        let target = LocalStore.folder(project.id)
        try FileManager.default.moveItem(at: stage, to: target)
        do {
            try Task.checkCancellation()
            try LocalStore.save(project)
        } catch {try? FileManager.default.removeItem(at: target); throw error}
        return project
    }
}
