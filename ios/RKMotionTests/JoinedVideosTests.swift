import XCTest
import AVFoundation
@testable import RKMotion

/// A project made of several videos plays them one after another on one
/// timeline, and every clip comes from a single video.
@MainActor final class JoinedVideosTests: XCTestCase {
    private let parts = ProjectPart.laid(["a.mov", "b.mov"], durations: [10, 15])
    private var folders: [URL] = []
    override func tearDown() async throws {
        folders.forEach {try? FileManager.default.removeItem(at: $0)}
        UserDefaults.standard.removeObject(forKey: "localProject")
    }
    private func folder(_ project: LocalProject) throws -> URL {
        let url = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url); return url
    }

    func testVideosAreLaidEndToEnd() {
        XCTAssertEqual(parts.map(\.start), [0, 10])
        XCTAssertEqual(parts.map(\.end), [10, 25])
        var project = LocalProject(name: "trip", source: "a.mov")
        project.parts = parts; project.duration = 25
        XCTAssertEqual(project.files, ["a.mov", "b.mov"])
        XCTAssertEqual(project.part(at: 12).file, "b.mov")
        XCTAssertEqual(project.part(at: 3).file, "a.mov")
        XCTAssertNil(project.part(for: Clip(start: 8, end: 12)))
        XCTAssertEqual(project.part(for: Clip(start: 10, end: 12))?.file, "b.mov")
        XCTAssertEqual(project.wholeClips.map(\.duration), [10, 15])
    }
    func testClipsAreCutAtTheSeam() {
        let crossing = Clip(start: 8, end: 14, score: 0.7)
        let fitted = ProjectPart.fit([crossing, Clip(start: 2, end: 5)], into: parts)
        XCTAssertEqual(fitted.map(\.start), [8, 10, 2])
        XCTAssertEqual(fitted.map(\.end), [10, 14, 5])
        XCTAssertEqual(fitted[0].uid, crossing.uid, "The first piece keeps the clip's identity")
        XCTAssertNotEqual(fitted[1].uid, crossing.uid)
        XCTAssertEqual(fitted[1].score, 0.7)
        // A sliver under a second is dropped; a clip made only of slivers keeps its longest.
        XCTAssertEqual(ProjectPart.fit([Clip(start: 9.5, end: 14)], into: parts).map(\.start), [10])
        XCTAssertEqual(ProjectPart.fit([Clip(start: 9.8, end: 10.3)], into: parts).map(\.end), [10.3])
        // One video: nothing changes.
        XCTAssertEqual(ProjectPart.fit([crossing], into: [parts[0]]), [crossing])
    }
    func testSplittingKeepsTheChosenClipsWithinTheLimit() {
        let parts = ProjectPart.laid(["a.mov", "b.mov"], durations: [Double(Edit.clipLimit) * 10 + 5, 100])
        var clips = (0..<Edit.clipLimit).map {Clip(start: Double($0) * 10, end: Double($0) * 10 + 8, score: 0.6)}
        clips[clips.count - 1] = Clip(start: parts[0].end - 3, end: parts[0].end + 3, score: 0.9)
        let fitted = ProjectPart.fit(clips, into: parts)
        XCTAssertEqual(fitted.count, Edit.clipLimit + 1)
        XCTAssertEqual(fitted.filter {$0.selected != false}.count, Edit.clipLimit)
    }
    func testSignalsJoinSecondBySecond() {
        let first = Signals(motion: [1, 2, 3], loudness: [0.1, 0.1, 0.1], people: [1, 1, 1], scenes: ["beach": 1])
        let second = Signals(motion: [7, 8], loudness: [0.2, 0.2], music: [0.9, 0.8], people: [3, 3], scenes: ["party": 1])
        let joined = Signals.joined([(first, 0, 2.5), (second, 2.5, 2)])
        XCTAssertEqual(joined.motion, [1, 2, 7, 8, 8])
        XCTAssertEqual(joined.music, [0, 0, 0.9, 0.8, 0.8], "Only the second video heard music")
        XCTAssertEqual(joined.speech, [], "No video measured speech")
        XCTAssertEqual(joined.scenes["beach"] ?? 0, 2.5 / 4.5, accuracy: 1e-9)
        XCTAssertEqual(joined.scenes["party"] ?? 0, 2 / 4.5, accuracy: 1e-9)
        XCTAssertEqual(joined.scores(for: .party).count, 5)
    }
    func testBeatSyncNeverGrowsAClipIntoTheNextVideo() {
        let clips = [Clip(start: 0, end: 9.6)]
        let free = Beats.synced(clips, beats: [0, 6, 10.4], speed: 1, transition: 0, sourceDuration: 25)
        XCTAssertEqual(free[0].end, 10.4, accuracy: 0.001)
        let bounded = Beats.synced(clips, beats: [0, 6, 10.4], speed: 1, transition: 0, sourceDuration: 25, seams: [10])
        XCTAssertEqual(bounded[0].end, 6, accuracy: 0.001)
    }
    func testAJoinedProjectSurvivesARestartOnlyWithAllItsVideos() throws {
        var project = LocalProject(name: "trip", source: "a.mov")
        project.parts = parts; project.duration = 25
        let url = try folder(project)
        try Data([0]).write(to: url.appendingPathComponent("a.mov"))
        try LocalStore.save(project)
        XCTAssertNil(LocalStore.load().first {$0.id == project.id}, "A missing video means the project cannot load")
        try Data([0]).write(to: url.appendingPathComponent("b.mov"))
        let restored = try XCTUnwrap(LocalStore.load().first {$0.id == project.id})
        XCTAssertEqual(restored.parts, parts)
    }
    func testUndatedVideosKeepThePickedOrder() async {
        let files = ["c", "a", "b"].map {FileManager.default.temporaryDirectory.appendingPathComponent($0 + ".mov")}
        let ordered = await EditorModel.chronological(files)
        XCTAssertEqual(ordered, files)
    }
    func testAnInterruptedImportOfSeveralVideosIsRescuedTogether() async throws {
        let id = UUID().uuidString
        folders.append(LocalStore.folder(id))
        try LocalStore.writeManifest(.init(name: "Trip", source: "source-1.mov", sources: ["source-1.mov", "source-2.mov", "source-3.mov"], bytes: 0, wholeVideo: false), project: id)
        try await UITestFixture.makeRide(LocalStore.file("source-1.mov", project: id), seconds: 1, width: 160, height: 120)
        try await UITestFixture.makeRide(LocalStore.file("source-2.mov", project: id), seconds: 2, width: 160, height: 120)
        // The third was still copying.
        try Data(count: 1024).write(to: LocalStore.file("source-3.mov.part", project: id))
        let recovery = await LocalStore.recoverImports()
        let rescued = try XCTUnwrap(recovery.rescued.first {$0.id == id})
        XCTAssertEqual(rescued.name, "Trip")
        XCTAssertEqual(rescued.files, ["source-1.mov", "source-2.mov"])
        XCTAssertEqual(rescued.parts?[1].start ?? 0, 1, accuracy: 0.05)
        XCTAssertNotNil(LocalStore.load().first {$0.id == id})
    }
    /// Two videos of different shapes, scanned as one and exported as one.
    func testJoinedVideosAreScannedAndExportedAsOneMovie() async throws {
        var project = LocalProject(name: "joined", source: "source-a.mov")
        let url = try folder(project)
        let a = url.appendingPathComponent("source-a.mov"), b = url.appendingPathComponent("source-b.mov")
        try await UITestFixture.makeRide(a, seconds: 3, width: 320, height: 240)
        try await UITestFixture.makeRide(b, seconds: 2, width: 240, height: 320)
        let engine = LocalEngine()
        let analysis = try await engine.analyze([a, b], whole: false) {_, _ in}
        XCTAssertEqual(analysis.duration, 5, accuracy: 0.1)
        XCTAssertEqual(analysis.durations.count, 2)
        XCTAssertEqual(analysis.signals?.motion.count, 5)
        project.parts = ProjectPart.laid(["source-a.mov", "source-b.mov"], durations: analysis.durations)
        project.duration = analysis.duration; project.analyzed = true
        XCTAssertTrue(analysis.clips.allSatisfy {project.part(for: $0) != nil}, "Suggested clips stay inside one video: \(analysis.clips)")
        let whole = try await engine.analyze([a, b], whole: true) {_, _ in}
        XCTAssertEqual(whole.clips.count, 2, "A video kept whole is one clip per video")

        var edit = Edit(clips: [Clip(start: 1, end: 2.8), Clip(start: 3.2, end: 4.8)])
        edit.settings["useMusic"] = .flag(false)
        edit.settings["transition"] = .text("slide"); edit.settings["transitionDuration"] = .text("0.3")
        let planned = await engine.plannedLength(project, edit: edit)
        let output = url.appendingPathComponent("joined.mp4")
        let length = try await engine.export(project, edit: edit, output: output) {_, _ in}
        XCTAssertEqual(try XCTUnwrap(planned), length, accuracy: 0.01)
        let actual = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(actual, length, accuracy: 0.1)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 240), "The first video sets the frame")

        let source = try await engine.joinedSource(project)
        let span = try await source.composition.load(.duration).seconds
        XCTAssertEqual(span, 5, accuracy: 0.1, "The joined source plays every video whole")

        let crossing = Edit(clips: [Clip(start: 2.5, end: 3.5)])
        let crossingLength = await engine.plannedLength(project, edit: crossing)
        XCTAssertNil(crossingLength)
        do {
            _ = try await engine.export(project, edit: crossing, output: url.appendingPathComponent("crossing.mp4")) {_, _ in}
            XCTFail("A clip across two videos was exported")
        } catch {}
    }
    func testImportingSeveralFilesMakesOneProject() async throws {
        let made = (0..<2).map {FileManager.default.temporaryDirectory.appendingPathComponent("rk-joined-\($0)-\(UUID().uuidString).mov")}
        defer {made.forEach {try? FileManager.default.removeItem(at: $0)}}
        try await UITestFixture.makeRide(made[0], seconds: 1, width: 160, height: 120)
        try await UITestFixture.makeRide(made[1], seconds: 2, width: 160, height: 120)
        let model = EditorModel()
        await model.importVideos(made)
        let project = try XCTUnwrap(model.project)
        folders.append(LocalStore.folder(project.id))
        model.cancel()
        for _ in 0..<200 where model.busy {try await Task.sleep(for: .milliseconds(50))}
        XCTAssertEqual(project.files.count, 2)
        XCTAssertEqual(project.files.first, project.source)
        XCTAssertEqual(project.parts?.map(\.duration).reduce(0, +) ?? 0, 3, accuracy: 0.1)
        XCTAssertNotNil(model.joinedSource)
        XCTAssertTrue(made.allSatisfy {FileManager.default.fileExists(atPath: $0.path)}, "The originals are untouched")
    }
}
