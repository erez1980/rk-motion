import Foundation

/// Serializes disk writes away from the UI. Revisions prevent an older
/// debounce task from overwriting a later explicit flush.
actor ProjectPersistence {
    private var revisions: [String: Int] = [:]
    private var scores: [String: [Double]] = [:]
    func load() -> [LocalProject] {LocalStore.load()}
    func save(_ project: LocalProject, revision: Int) throws {
        try Task.checkCancellation()
        guard revision >= revisions[project.id, default: -1] else {return}
        let writeScores = scores[project.id] != project.scores
        try LocalStore.save(project, writeScores: writeScores)
        scores[project.id] = project.scores
        revisions[project.id] = revision
    }
    func deleteExport(_ export: LocalExport, from project: LocalProject, revision: Int) throws {
        try save(project, revision: revision)
        let file = LocalStore.file(export.file, project: project.id)
        if FileManager.default.fileExists(atPath: file.path) {try FileManager.default.removeItem(at: file)}
    }
    func deleteProject(_ id: String) throws {
        try FileManager.default.removeItem(at: LocalStore.folder(id))
        revisions.removeValue(forKey: id); scores.removeValue(forKey: id)
    }
    func bytes(_ project: LocalProject) -> Int64 {LocalStore.bytes(in: LocalStore.folder(project.id))}
}
