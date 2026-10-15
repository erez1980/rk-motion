import Foundation

/// Serializes disk writes away from the UI. Revisions prevent an older
/// debounce task from overwriting a later explicit flush.
///
/// Revisions alone cannot stop a snapshot that is older in content but newer
/// in number: the save made when the app goes to the background can copy the
/// project while a deletion is still on its way to disk. So the actor also
/// remembers what this run deleted, and no later write brings it back: a
/// deleted project is never written again, and a removed export or song is
/// left out of any snapshot that still lists it.
actor ProjectPersistence {
    private var revisions: [String: Int] = [:]
    private var scoreFiles: [String: String] = [:]
    private var scores: [String: [Double]] = [:]
    private var deleted: Set<String> = []
    private var retired: [String: Set<String>] = [:]
    typealias Gate = @Sendable (LocalProject, Int) async -> Void
    private var gate: Gate?
    /// Tests hold a write here to force the interleavings real use produces.
    func setGate(_ gate: Gate?) {self.gate = gate}
    func load() -> [LocalProject] {LocalStore.load()}
    func save(_ project: LocalProject, revision: Int) async throws {
        if let gate {await gate(project, revision)}
        try Task.checkCancellation()
        try write(project, revision: revision)
    }
    private func write(_ original: LocalProject, revision: Int) throws {
        guard !deleted.contains(original.id), revision >= revisions[original.id, default: -1] else {return}
        var project = original
        if let gone = retired[project.id] {
            project.exports.removeAll {gone.contains($0.file)}
            project.music.removeAll {gone.contains($0.file)}
        }
        let writeScores = scores[project.id] != project.scores
        let scoreFile = try LocalStore.save(project, writeScores: writeScores, scoresFile: scoreFiles[project.id])
        scoreFiles[project.id] = scoreFile
        scores[project.id] = project.scores
        revisions[project.id] = revision
    }
    /// Saves `project`, which no longer lists `file`, then removes the file.
    /// Returns why the file could not be removed, if it could not.
    private func remove(_ file: String, from project: LocalProject, revision: Int) async throws -> String? {
        retired[project.id, default: []].insert(file)
        do {try await save(project, revision: revision)}
        catch {retired[project.id]?.remove(file); throw error}
        let url = LocalStore.file(file, project: project.id)
        do {
            if FileManager.default.fileExists(atPath: url.path) {try FileManager.default.removeItem(at: url)}
            return nil
        } catch {return error.localizedDescription}
    }
    func deleteExport(_ export: LocalExport, from project: LocalProject, revision: Int) async throws -> String? {
        try await remove(export.file, from: project, revision: revision)
    }
    func removeMusic(_ song: LocalMusic, from project: LocalProject, revision: Int) async throws -> String? {
        try await remove(song.file, from: project, revision: revision)
    }
    func deleteProject(_ id: String) throws {
        deleted.insert(id)
        do {try FileManager.default.removeItem(at: LocalStore.folder(id))}
        catch {deleted.remove(id); throw error}
        revisions.removeValue(forKey: id); scores.removeValue(forKey: id); scoreFiles.removeValue(forKey: id); retired.removeValue(forKey: id)
    }
    func cleanTemporaryFiles() async throws -> Int64 {try await LocalStore.cleanTemporaryFiles()}
    func bytes(_ project: LocalProject) -> Int64 {LocalStore.bytes(in: LocalStore.folder(project.id))}
}
