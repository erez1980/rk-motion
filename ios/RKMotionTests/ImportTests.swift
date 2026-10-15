import XCTest
@testable import RKMotion

/// F03 and F04: an import is one cancellable operation, staged behind a
/// manifest, and what an interrupted one leaves is rescued, never deleted
/// on its own.
@MainActor final class ImportTests: XCTestCase {
    private var made: [URL] = []
    private var before: Set<String> = []
    override func setUp() async throws {
        before = Set(LocalStore.projectFolders().map(\.lastPathComponent))
    }
    override func tearDown() async throws {
        LocalStore.copyObserver = nil; LocalStore.copyChunk = 8 << 20
        made.forEach {try? FileManager.default.removeItem(at: $0)}
        for folder in LocalStore.projectFolders() where !before.contains(folder.lastPathComponent) {try? FileManager.default.removeItem(at: folder)}
        for url in (try? FileManager.default.contentsOfDirectory(at: LocalStore.imports, includingPropertiesForKeys: nil)) ?? [] {try? FileManager.default.removeItem(at: url)}
        UserDefaults.standard.removeObject(forKey: "localProject")
    }
    private func newFolders() -> [URL] {LocalStore.projectFolders().filter {!before.contains($0.lastPathComponent)}}
    private func temporary(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name); made.append(url); return url
    }

    /// The old import ran outside the cancellable operation: "cancel" did
    /// nothing while the copy ran and the project was created anyway.
    func testCancellingDuringTheCopyStopsItAndLeavesNoProject() async throws {
        let big = temporary("ride.mov")
        try Data(count: 6 << 20).write(to: big)
        LocalStore.copyChunk = 1 << 20
        let gate = WriteGate()
        LocalStore.copyObserver = {_ in await gate.pass()}
        let model = EditorModel()
        let importing = Task {await model.importVideo(big)}
        await gate.firstArrival()
        XCTAssertTrue(model.canCancel, "The copy must belong to the cancellable operation")
        model.cancel()
        await gate.release()
        await importing.value
        XCTAssertNil(model.project)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.message, "ייבוא הסרטון בוטל")
        XCTAssertEqual(newFolders(), [], "A cancelled import leaves no folder, manifest or partial copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: big.path), "The rider's original is untouched")
    }

    func testAnInterruptedImportIsRescuedAndOnlyFragmentsAreCleaned() async throws {
        let ride = temporary("ride.mov")
        try await UITestFixture.makeRide(ride, seconds: 1, width: 160, height: 120)
        // 1. The copy finished but the app stopped before saving the project.
        let whole = UUID().uuidString
        try LocalStore.writeManifest(.init(name: "Morning ride", source: "source-a.mov", bytes: 0, wholeVideo: true), project: whole)
        try FileManager.default.copyItem(at: ride, to: LocalStore.file("source-a.mov", project: whole))
        // 2. The app stopped in the middle of the copy.
        let cut = UUID().uuidString
        try LocalStore.writeManifest(.init(name: "Cut short", source: "source-b.mov", bytes: 1 << 20, wholeVideo: false), project: cut)
        try Data(count: 4096).write(to: LocalStore.file("source-b.mov.part", project: cut))
        // 3. An older version's folder: a whole source, no manifest, no project.
        let legacy = UUID().uuidString
        try FileManager.default.createDirectory(at: LocalStore.folder(legacy), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ride, to: LocalStore.file("source-c.mov", project: legacy))
        // 4. The photo picker had handed over a movie, and a piece of another.
        let picked = LocalStore.imports.appendingPathComponent(UUID().uuidString + ".mov")
        try FileManager.default.copyItem(at: ride, to: picked)
        let piece = LocalStore.imports.appendingPathComponent(UUID().uuidString + ".mov.part")
        try Data(count: 2048).write(to: piece)

        let recovery = await LocalStore.recoverImports()
        XCTAssertEqual(recovery.rescued.count, 3)
        let loaded = LocalStore.load()
        let first = try XCTUnwrap(loaded.first {$0.id == whole})
        XCTAssertEqual(first.name, "Morning ride"); XCTAssertTrue(first.wholeVideo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.file(LocalStore.manifestName, project: whole).path))
        XCTAssertNotNil(loaded.first {$0.id == legacy})
        XCTAssertTrue(recovery.rescued.contains {$0.id != whole && $0.id != legacy}, "The picked movie became a project")
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path))
        // Nothing was deleted by recovery: the fragments wait for the rider.
        XCTAssertGreaterThan(recovery.fragmentBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalStore.file("source-b.mov.part", project: cut).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: piece.path))

        // The rider's cleanup removes only the fragments.
        _ = try await LocalStore.cleanTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.folder(cut).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: piece.path))
        let after = Set(LocalStore.load().map(\.id))
        for p in recovery.rescued {XCTAssertTrue(after.contains(p.id))}
    }

    /// The old cleanup emptied the picker's hand-over folder blindly.
    func testCleanupRescuesAPlayableMovieInsteadOfDeletingIt() async throws {
        let picked = LocalStore.imports.appendingPathComponent(UUID().uuidString + ".mov")
        try await UITestFixture.makeRide(picked, seconds: 1, width: 160, height: 120)
        _ = try await LocalStore.cleanTemporaryFiles()
        XCTAssertEqual(newFolders().count, 1)
        let rescued = try XCTUnwrap(LocalStore.load().first {$0.id == newFolders().first?.lastPathComponent})
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalStore.file(rescued.source, project: rescued.id).path))
    }
}
