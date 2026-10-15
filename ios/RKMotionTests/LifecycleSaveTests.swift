import XCTest
@testable import RKMotion

/// Holds the first write that reaches it until released, so a test can make
/// another save happen in the middle of a deletion, as backgrounding does.
actor WriteGate {
    private var arrivals = 0, open = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []
    func pass() async {
        arrivals += 1
        watchers.forEach {$0.resume()}; watchers = []
        guard arrivals == 1, !open else {return}
        await withCheckedContinuation {held.append($0)}
    }
    func firstArrival() async {
        if arrivals > 0 {return}
        await withCheckedContinuation {watchers.append($0)}
    }
    func release() {open = true; held.forEach {$0.resume()}; held = []}
}

/// F02: a lifecycle save must never put back what a deletion removed.
@MainActor final class LifecycleSaveTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() async throws {
        folders.forEach {try? FileManager.default.removeItem(at: $0)}
        UserDefaults.standard.removeObject(forKey: "localProject")
    }
    private func project(exports: [String] = [], songs: [String] = []) throws -> LocalProject {
        var p = LocalProject(name: "lifecycle", source: "source.mov")
        let folder = LocalStore.folder(p.id); folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: LocalStore.file(p.source, project: p.id))
        for name in exports + songs {try Data([1, 2]).write(to: LocalStore.file(name, project: p.id))}
        p.duration = 10; p.analyzed = true; p.edit.clips = [Clip(start: 1, end: 4)]
        p.exports = exports.map {LocalExport(file: $0, duration: 3)}
        p.music = songs.map {LocalMusic(file: $0, name: $0, duration: 30)}
        try LocalStore.save(p)
        return p
    }
    private func onDisk(_ id: String) -> LocalProject? {LocalStore.load().first {$0.id == id}}

    /// Deterministic: a snapshot that still lists the export reaches the disk
    /// after the deletion, and with a higher revision.
    func testAStaleSnapshotWithAHigherRevisionCannotBringAnExportBack() async throws {
        let stale = try project(exports: ["RK-Motion-a.mp4"])
        var without = stale; without.exports = []
        let store = ProjectPersistence()
        _ = try await store.deleteExport(stale.exports[0], from: without, revision: 1)
        try await store.save(stale, revision: 2)
        XCTAssertEqual(onDisk(stale.id)?.exports.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.file("RK-Motion-a.mp4", project: stale.id).path))
    }
    func testAStaleSnapshotCannotBringASongBack() async throws {
        let stale = try project(songs: ["music-a.m4a"])
        var without = stale; without.music = []
        let store = ProjectPersistence()
        _ = try await store.removeMusic(stale.music[0], from: without, revision: 1)
        try await store.save(stale, revision: 2)
        XCTAssertEqual(onDisk(stale.id)?.music.count, 0)
    }
    func testNoWriteRecreatesADeletedProject() async throws {
        let p = try project()
        let store = ProjectPersistence()
        try await store.deleteProject(p.id)
        try await store.save(p, revision: 99)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.folder(p.id).path))
    }

    /// With barriers: the deletion's write is held on its way to disk while
    /// the app goes to the background and saves.
    func testBackgroundingDuringExportDeletionKeepsItDeleted() async throws {
        let p = try project(exports: ["RK-Motion-a.mp4", "RK-Motion-b.mp4"])
        let store = ProjectPersistence(), gate = WriteGate()
        let model = EditorModel(persistence: store)
        await model.open(p)
        XCTAssertEqual(model.project?.id, p.id)
        await store.setGate {_, _ in await gate.pass()}
        let deletion = Task {await model.deleteExport(p.exports[0])}
        await gate.firstArrival()
        model.pause()
        await gate.release()
        await deletion.value
        await model.settleSaves()
        XCTAssertEqual(onDisk(p.id)?.exports.map(\.file), ["RK-Motion-b.mp4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.file("RK-Motion-a.mp4", project: p.id).path))
        XCTAssertEqual(model.project?.exports.map(\.file), ["RK-Motion-b.mp4"])
    }
    func testBackgroundingDuringSongRemovalKeepsItRemoved() async throws {
        let p = try project(songs: ["music-a.m4a"])
        let store = ProjectPersistence(), gate = WriteGate()
        let model = EditorModel(persistence: store)
        await model.open(p)
        await store.setGate {_, _ in await gate.pass()}
        let removal = Task {await model.removeMusic(p.music[0].id)}
        await gate.firstArrival()
        model.pause()
        await gate.release()
        await removal.value
        await model.settleSaves()
        XCTAssertEqual(onDisk(p.id)?.music.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.file("music-a.m4a", project: p.id).path))
    }
    /// The background save starts first and is held; the rider deletes the
    /// project; then the held save is let through.
    func testABackgroundSaveHeldDuringProjectDeletionCannotRecreateIt() async throws {
        let p = try project()
        let store = ProjectPersistence(), gate = WriteGate()
        let model = EditorModel(persistence: store)
        await model.open(p)
        await store.setGate {_, _ in await gate.pass()}
        model.pause()
        await gate.firstArrival()
        await model.reset()
        await gate.release()
        await model.settleSaves()
        XCTAssertNil(model.project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.folder(p.id).path))
        XCTAssertNil(onDisk(p.id))
    }
}
