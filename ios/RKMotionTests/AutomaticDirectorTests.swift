import XCTest
import AVFoundation
import CoreImage
@testable import RKMotion

final class AutomaticDirectorTests: XCTestCase {
    private func project(seconds: Double = 30) -> LocalProject {
        var p = LocalProject(name: "Automatic test", source: "source.mov")
        p.duration = seconds; p.analyzed = true
        return p
    }
    private func event(_ id: String, _ start: Double, _ end: Double, score: Double = 0.8, reason: AutomaticEvent.Reason = .motion) -> AutomaticEvent {
        AutomaticEvent(id: id, file: "source.mov", start: start, peak: (start + end) / 2, end: end, score: score, reason: reason)
    }
    func testWholeEventSurvivesEvenWhenLongerThanBudgetAndCannotBeBeatTrimmed() {
        let events = [event("long", 0, 12), event("second", 15, 20)]
        let chosen = AutomaticDirector.choose(events, seconds: 5, style: .personal)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen[0].end, 12)
        var edit = Edit(clips: chosen)
        edit.settings["preserveEvents"] = .flag(true)
        var p = project(); p.music = [LocalMusic(file: "song.caf", name: "Song", duration: 30)]
        XCTAssertFalse(LocalEngine.syncsToBeat(edit, project: p))
    }
    func testRecipeChangesContentAndPreservesManualIntervals() {
        let events = [event("movement", 0, 5, score: 0.7), event("scene", 10, 15, score: 0.7, reason: .scenery)]
        XCTAssertEqual(AutomaticDirector.choose(events, seconds: 5, style: .action).first?.uid, "movement")
        XCTAssertEqual(AutomaticDirector.choose(events, seconds: 5, style: .cinematic).first?.uid, "scene")
        var locked = Clip(start: 1, end: 4); locked.manual = true
        let kept = AutomaticDirector.choose(events, seconds: 5, style: .cinematic, locked: [locked])
        XCTAssertEqual(kept.first?.uid, locked.uid)
        XCTAssertFalse(kept.contains {$0.uid == "movement"})
    }
    func testEventsKeepSpeechEndingAndStayInTheirSource() {
        var p = project(seconds: 20)
        p.parts = [ProjectPart(file: "source.mov", start: 0, duration: 10), ProjectPart(file: "second.mov", start: 10, duration: 10)]
        var signals = Signals(motion: Array(repeating: 0.01, count: 20), loudness: Array(repeating: 0.1, count: 20))
        signals.speech = (0..<20).map {2...8 ~= $0 ? 0.9 : 0}
        signals.cheer = Array(repeating: 0, count: 20)
        let found = AutomaticDirector.events(project: p, signals: signals)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy {$0.start >= 0 && $0.end <= 20 && p.part(for: $0.clip) != nil})
        XCTAssertTrue(found.contains {$0.start <= 2 && $0.end >= 9})
        XCTAssertLessThanOrEqual(found.count, AutomaticDirector.eventLimit)
    }
    func testQuietBeautifulMomentCanBeatLoudPoorFootage() {
        let p = project(seconds: 12)
        var signals = Signals(motion: Array(repeating: 0.1, count: 12), loudness: Array(repeating: 0.9, count: 12))
        signals.beauty = (0..<12).map {$0 >= 6 ? 0.95 : 0}
        signals.sharpness = (0..<12).map {$0 >= 6 ? 0.8 : 0.001}
        signals.brightness = (0..<12).map {$0 >= 6 ? 0.5 : 0.01}
        let found = AutomaticDirector.events(project: p, signals: signals)
        let chosen = AutomaticDirector.choose(found, seconds: 5, style: .cinematic)
        XCTAssertTrue(chosen.first.map {$0.start >= 4} ?? false)
    }
    func testCriticRemovesInvalidDuplicatesAndRestoresEnding() {
        let p = project()
        let full = event("main", 2, 9)
        var short = full.clip; short.end = 6
        var edit = Edit(clips: [short, short, Clip(start: -.infinity, end: 4), Clip(start: 4, end: 40)])
        let report = AutomaticDirector.review(&edit, project: p, events: [full])
        XCTAssertEqual(report.removedInvalid, 2)
        XCTAssertEqual(report.removedDuplicate, 1)
        XCTAssertEqual(report.restoredEnding, 1)
        XCTAssertEqual(edit.clips.map(\.end), [9])
    }
    func testFocusMovesSmoothlyAndHandlesAbsentDetections() {
        let path = AutomaticDirector.focusPath([0, 1, 1, .nan, -1, 0])
        for pair in zip([0.5] + path, path) {XCTAssertLessThanOrEqual(abs(pair.1 - pair.0), 0.08001)}
        XCTAssertTrue(path.allSatisfy {$0.isFinite && 0...1 ~= $0})
    }
    func testPersonalizationDoesNotTrainOnAutomaticOutputs() {
        var taste = AutomaticTaste()
        var edit = Edit(clips: [])
        edit.settings["beatZoom"] = .flag(true)
        edit.settings["aspect"] = .text("source")
        taste.learn(edit)
        XCTAssertEqual(taste.observations, 1)
        XCTAssertEqual(taste.zoom, 1)
        XCTAssertEqual(taste.portrait, 0)
        let previous = taste
        edit.settings["automatic"] = .flag(true); taste.learn(edit)
        XCTAssertEqual(taste, previous)
        let settings = AutomaticStyle.personal.settings(kind: .general, taste: taste)
        XCTAssertEqual(settings["aspect"]?.string, "source")
    }
    func testOneTapChoicesTeachTasteWithoutLearningFromBatchOutputs() {
        var taste = AutomaticTaste()
        taste.choose(.cinematic); taste.choose(.cinematic); taste.choose(.action)
        XCTAssertEqual(taste.preferredStyle, .cinematic)
        taste.choose(.personal)
        XCTAssertEqual(taste.choices.count, 2)
    }
    func testInvalidInputsAndAmbiguousMatchesDoNotCreateContent() {
        XCTAssertTrue(AutomaticDirector.events(project: project(seconds: .nan), signals: Signals()).isEmpty)
        var malformed = project()
        malformed.parts = [ProjectPart(file: "bad.mov", start: 0, duration: 1e300)]
        XCTAssertTrue(AutomaticDirector.events(project: malformed, signals: Signals(motion: [0.1])).isEmpty)
        XCTAssertTrue(AutomaticDirector.choose([event("x", 0, 3)], seconds: .nan, style: .action).isEmpty)
        XCTAssertFalse(AutomaticVision.accepted(best: .nan, runnerUp: 1))
        XCTAssertFalse(AutomaticVision.accepted(best: 0.1, runnerUp: 0.11))
        XCTAssertFalse(AutomaticVision.accepted(best: 0.8, runnerUp: 1))
        XCTAssertTrue(AutomaticVision.accepted(best: 0.1, runnerUp: 0.5))
    }
    func testSourceNotesUseFileTimeAcrossJoinedAndRepeatedSources() {
        var p = project()
        p.parts = [ProjectPart(file: "source.mov", start: 0, duration: 10),
                   ProjectPart(file: "second.mov", start: 10, duration: 10),
                   ProjectPart(file: "source.mov", start: 20, duration: 10)]
        var second = event("second", 12, 16); second.file = "second.mov"
        let events = [event("first", 2, 5), second, event("repeated", 22, 26), event("invalid-seam", 8, 12)]
        let edit = Edit(clips: events.map(\.clip))
        let run = AutomaticRun(sourceFiles: p.files, style: .family, events: events, review: .init(), edit: edit)
        let report = AutomaticInsights.make(run, signals: Signals(), project: p)
        XCTAssertEqual(report.insights.map(\.file), ["source.mov", "second.mov", "source.mov"])
        XCTAssertEqual(report.insights.map(\.start), [2, 2, 2])
        XCTAssertEqual(report.insights.map(\.end), [5, 6, 6])
        XCTAssertEqual(run.edit.clips.map(\.start), [2, 12, 22, 8], "Evidence conversion must not mutate the render timeline")
    }
}

final class AutomaticMediaTests: XCTestCase {
    func testOriginalScoreWritesBoundedFinitePCMAndCancelsCleanly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let file = folder.appendingPathComponent("music.caf")
        try await AutomaticMusic.make(kind: .action, style: .action, seconds: 1, at: file)
        let audio = try AVAudioFile(forReading: file)
        XCTAssertEqual(audio.length, 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 44100)!
        try audio.read(into: buffer)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        XCTAssertTrue(samples.allSatisfy {$0.isFinite && abs($0) <= 1})
        XCTAssertTrue(samples.contains {abs($0) > 0.01})
        let cancelled = folder.appendingPathComponent("cancelled.caf")
        let task = Task {try await AutomaticMusic.make(kind: .action, style: .action, seconds: 120, at: cancelled)}
        task.cancel()
        do {try await task.value; XCTFail("Cancelled score must not publish a file")} catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["music.caf"])
    }
    func testExportValidationRejectsMissingMediaAndComparisonPreservesDuration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let first = folder.appendingPathComponent("one.mov"), second = folder.appendingPathComponent("two.mov")
        try await UITestFixture.makeRide(first)
        try await UITestFixture.makeRide(second)
        let out = folder.appendingPathComponent("comparison.mp4")
        let duration = try await AutomaticComparison.export(left: first, right: second, match: .init(leftTime: 1, rightTime: 2, distance: 0.1), output: out)
        XCTAssertEqual(duration, 3, accuracy: 0.05)
        try await AutomaticStore.validateMovie(out, expected: 3)
        do {try await AutomaticStore.validateMovie(out, expected: 50); XCTFail("Truncated output accepted")} catch {}
    }
    func testAlternatingMulticamActuallySwitchesItsRenderedAngle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let left = folder.appendingPathComponent("wide.mov"), right = folder.appendingPathComponent("tall.mov")
        try await UITestFixture.makeRide(left)
        try await UITestFixture.makeRide(right, width: 240, height: 320)
        let output = folder.appendingPathComponent("multicam.mp4")
        _ = try await AutomaticComparison.export(left: left, right: right, match: .init(leftTime: 1, rightTime: 2, distance: 0), output: output, alternating: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        let context = CIContext()
        func corner(_ time: Double) async throws -> Int {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(CIImage(cgImage: frame), toBitmap: &rgba, rowBytes: 4, bounds: CGRect(x: 20, y: 540, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            return Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])
        }
        let wide = try await corner(0.5), tall = try await corner(2.5)
        XCTAssertGreaterThan(wide, 10)
        XCTAssertLessThan(tall, 5)
    }
    func testPersistentVersionsDoNotRequireTheInMemoryUndoStack() throws {
        let project = UUID().uuidString
        try FileManager.default.createDirectory(at: LocalStore.folder(project), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(project))}
        for number in 0..<25 {try AutomaticStore.checkpoint(Edit(clips: [Clip(start: 0, end: Double(number + 1))]), style: .action, project: project)}
        let versions = AutomaticStore.versions(project)
        XCTAssertEqual(versions.count, 20)
        XCTAssertEqual(versions.first?.edit.clips.first?.end, 6)
        XCTAssertEqual(versions.last?.edit.clips.first?.end, 25)
    }
    @MainActor func testOneTapRunsAnalysisMusicReviewExportAndPersistentReceipt() async throws {
        let id = UUID().uuidString, folder = LocalStore.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let file = folder.appendingPathComponent("source.mov")
        try await UITestFixture.makeRide(file)
        var p = LocalProject(id: id, name: "Automatic integration", source: "source.mov")
        p.duration = 4
        try LocalStore.save(p)
        let model = EditorModel()
        await model.open(p)
        model.automaticMovie(savePhotos: false)
        let deadline = Date().addingTimeInterval(120)
        while model.busy && Date() < deadline {try await Task.sleep(for: .milliseconds(100))}
        XCTAssertFalse(model.busy, model.message)
        XCTAssertTrue(model.automaticRun?.completed == true, model.message)
        XCTAssertEqual(model.project?.exports.count, 1, model.message)
        XCTAssertEqual(model.project?.music.count, 1, model.message)
        let run = try XCTUnwrap(AutomaticStore.read(AutomaticRun.self, name: "automatic-run.json", project: id))
        XCTAssertTrue(run.completed)
        XCTAssertFalse(run.events.isEmpty)
        XCTAssertEqual(run.sourceFiles, ["source.mov"])
        let output = try XCTUnwrap(model.movieURL)
        try await AutomaticStore.validateMovie(output, expected: model.project!.exports[0].duration)
        await model.settleSaves()
    }
    func testAudioSynchronizationRejectsSilenceAndFindsAnUnambiguousOffset() {
        XCTAssertNil(AutomaticSync.align(Array(repeating: 1, count: 100), Array(repeating: 1, count: 100), rate: 10))
        var seed: UInt64 = 54321
        let source: [Double] = (0..<300).map {_ in seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 40) / Double(1 << 24)}
        let delayed = Array(repeating: 0.0, count: 20) + source
        let found = AutomaticSync.align(delayed, source, rate: 10)
        XCTAssertEqual(found?.offset ?? -99, 2, accuracy: 0.01)
        XCTAssertGreaterThan(found?.correlation ?? 0, 0.98)
    }
    func testPackageIsARealZipWithSourcesAndMetadata() async throws {
        let id = UUID().uuidString
        let folder = LocalStore.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let source = folder.appendingPathComponent("source.mov")
        try await UITestFixture.makeRide(source)
        var project = LocalProject(id: id, name: "Package test", source: "source.mov")
        project.duration = 4
        let output = try await AutomaticStore.archive(project, edit: Edit(clips: [Clip(start: 0, end: 4)]))
        let data = try Data(contentsOf: output)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4b])
        XCTAssertTrue(output.path.hasPrefix(folder.path))
        let checksum = try await AutomaticStore.digest(source)
        XCTAssertFalse(checksum.isEmpty)
        let restored = try await AutomaticPackage.restore(output)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(restored.id))}
        XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(restored.name, project.name)
        XCTAssertEqual(restored.edit.clips.map(\.end), [4])
        let restoredHash = try await AutomaticStore.digest(LocalStore.file(restored.source, project: restored.id))
        XCTAssertEqual(restoredHash, checksum)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let damaged = folder.appendingPathComponent("damaged.zip")
        try Data(data.prefix(100)).write(to: damaged)
        do { _ = try await AutomaticPackage.restore(damaged); XCTFail("A truncated package must be rejected") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testPackagePathsRejectTraversalAndAmbiguousNames() {
        for path in ["../source.mov", "/source.mov", "folder/../source.mov", "folder//source.mov", "folder\\source.mov", "./source.mov"] {
            XCTAssertNil(AutomaticPackage.safeName(path), path)
        }
        XCTAssertEqual(AutomaticPackage.safeName("package/source.mov"), "source.mov")
        XCTAssertEqual(AutomaticPackage.safeName("source.mov"), "source.mov")
    }
    func testBackupRejectsSourcesAndSidecarsThatRestoreCannotAccept() async throws {
        let id = UUID().uuidString, folder = LocalStore.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        func sparse(_ name: String, size: UInt64) throws {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            defer {try? handle.close()}
            try handle.truncate(atOffset: size)
        }
        let project = LocalProject(id: id, name: "Oversized backup", source: "source.mov")
        try sparse("source.mov", size: AutomaticPackage.maximumBytes + 1)
        do {_ = try await AutomaticStore.archive(project, edit: Edit(clips: [])); XCTFail("Unrestorable source accepted")}
        catch let error as CocoaError {XCTAssertEqual(error.code, .fileReadCorruptFile)}
        XCTAssertEqual(try folder.appendingPathComponent("source.mov").resourceValues(forKeys: [.fileSizeKey]).fileSize, Int(AutomaticPackage.maximumBytes + 1))
        try sparse("source.mov", size: 4)
        try sparse(LocalStore.signalsName, size: 32 * 1024 * 1024 + 1)
        do {_ = try await AutomaticStore.archive(project, edit: Edit(clips: [])); XCTFail("Unrestorable JSON accepted")}
        catch let error as CocoaError {XCTAssertEqual(error.code, .fileReadCorruptFile)}
        let packages = folder.appendingPathComponent("packages")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: packages.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(LocalStore.signalsName).path))
    }
}
