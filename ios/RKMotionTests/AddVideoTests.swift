import XCTest
import AVFoundation
@testable import RKMotion

/// A video added to an open project goes at its end: only the new video is
/// scanned, the clips already made stay, the new video gives the movie a
/// moment, and undo brings the earlier edit back.
@MainActor final class AddVideoTests: XCTestCase {
    private var folders: [URL] = []
    private var made: [URL] = []
    override func tearDown() async throws {
        folders.forEach {try? FileManager.default.removeItem(at: $0)}
        made.forEach {try? FileManager.default.removeItem(at: $0)}
        UserDefaults.standard.removeObject(forKey: "localProject")
    }
    private func idle(_ model: EditorModel) async throws {
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline {try await Task.sleep(for: .milliseconds(100))}
        XCTAssertFalse(model.busy, model.message)
    }

    /// The saved signals of the first video and the new video's own scan
    /// read as the same timeline a scan of both together would.
    func testExtendingJoinsTheNewScanToTheSavedSignals() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); folders.append(url)
        let a = url.appendingPathComponent("a.mov"), b = url.appendingPathComponent("b.mov")
        try await UITestFixture.makeRide(a, seconds: 3, width: 320, height: 240)
        try await UITestFixture.makeRide(b, seconds: 2, width: 240, height: 320)
        let engine = LocalEngine()
        let first = try await engine.analyze([a], whole: false) {_, _ in}
        let extended = try await engine.extend(try XCTUnwrap(first.signals), before: first.duration, adding: [b]) {_, _ in}
        let both = try await engine.analyze([a, b], whole: false) {_, _ in}
        XCTAssertEqual(extended.durations.count, 1)
        XCTAssertEqual(extended.durations[0], 2, accuracy: 0.1)
        XCTAssertEqual(extended.signals.motion.count, both.signals?.motion.count)
        XCTAssertEqual(extended.signals.loudness.count, both.signals?.loudness.count)
    }

    func testAddingAVideoKeepsTheEditAndGivesTheNewVideoAMoment() async throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-a.mov")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-b.mov")
        made += [a, b]
        try await UITestFixture.makeRide(a, seconds: 6, width: 320, height: 240)
        try await UITestFixture.makeRide(b, seconds: 5, width: 320, height: 240)
        let model = EditorModel()
        await model.importVideos([a])
        try await idle(model)
        let first = try XCTUnwrap(model.project, model.message)
        folders.append(LocalStore.folder(first.id))
        XCTAssertTrue(first.analyzed, model.message)
        let before = model.edit, length = first.duration

        await model.importVideos([b], adding: true)
        try await idle(model)
        let project = try XCTUnwrap(model.project)
        XCTAssertEqual(project.id, first.id, "The video joins the open project instead of starting a new one")
        XCTAssertEqual(project.files.count, 2)
        XCTAssertEqual(project.files.first, first.source)
        XCTAssertEqual(project.duration, length + 5, accuracy: 0.2)
        XCTAssertEqual(LocalStore.readSignals(project: project.id)?.motion.count, Int(ceil(project.duration)))
        let added = try XCTUnwrap(project.parts?.last)
        XCTAssertTrue(model.edit.clips.contains {ClipRules.inside($0, added)}, "The new video gives the movie a moment: \(model.edit.clips)")
        XCTAssertTrue(model.edit.clips.allSatisfy {project.part(for: $0) != nil}, "Every clip stays inside one video")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "The rider's original is untouched")

        model.undo()
        XCTAssertEqual(model.edit.clips, before.clips, "Undo brings the edit from before the addition back")
        await model.settleSaves()
    }

    /// A cancelled addition removes its own copy and leaves the project as it was.
    func testCancellingAnAdditionLeavesTheProjectAsItWas() async throws {
        let a = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-a.mov")
        let big = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-big.mov")
        made += [a, big]
        try await UITestFixture.makeRide(a, seconds: 3, width: 320, height: 240)
        try Data(count: 6 << 20).write(to: big)
        let model = EditorModel()
        await model.importVideos([a])
        try await idle(model)
        let first = try XCTUnwrap(model.project)
        folders.append(LocalStore.folder(first.id))
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: LocalStore.folder(first.id).path))
        LocalStore.copyChunk = 1 << 20
        let gate = WriteGate()
        LocalStore.copyObserver = {_ in await gate.pass()}
        defer {LocalStore.copyObserver = nil; LocalStore.copyChunk = 8 << 20}
        let adding = Task {await model.importVideos([big], adding: true)}
        await gate.firstArrival()
        model.cancel()
        await gate.release()
        await adding.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.project?.files, first.files)
        XCTAssertEqual(model.project?.duration, first.duration)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: LocalStore.folder(first.id).path)), files,
                       "A cancelled addition leaves no copy behind")
        await model.settleSaves()
    }
}
