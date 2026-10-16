import XCTest
@testable import RKMotion

final class ReadinessTests: XCTestCase {
    func testPaddedActivityWindowsMergeAndStayChronological() {
        var scores = [Double](repeating: 0, count: 40)
        scores[5] = 0.7; scores[9] = 0.8; scores[25] = 1
        let clips = LocalEngine.ranges(scores: scores, duration: 40)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].start, 3)
        XCTAssertEqual(clips[0].end, 12)
        XCTAssertLessThanOrEqual(clips[0].end, clips[1].start)
    }
    func testOldRevisionCannotOverwriteNewerEdit() async throws {
        let store = ProjectPersistence()
        var p = LocalProject(name: "revision", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(p.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        try Data([0]).write(to: LocalStore.file(p.source, project: p.id))
        let old = p
        p.edit.clips = [Clip(start: 1, end: 4)]
        try await store.save(p, revision: 2)
        try await store.save(old, revision: 1)
        let loaded = await store.load()
        XCTAssertEqual(loaded.first {$0.id == p.id}?.edit, p.edit)
    }
    func testSplitScoresAndLegacyProjectsRemainReadable() throws {
        var p = LocalProject(name: "scores", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(p.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        try Data([0]).write(to: LocalStore.file(p.source, project: p.id))
        p.scores = [0.2, 0.8]; p.duration = 2
        let scoreFile = try LocalStore.save(p)
        let data = try Data(contentsOf: LocalStore.file("project.json", project: p.id))
        XCTAssertTrue(try JSONDecoder().decode(LocalProject.self, from: data).scores.isEmpty)
        XCTAssertEqual(LocalStore.load().first {$0.id == p.id}?.scores, p.scores)
        try FileManager.default.removeItem(at: LocalStore.file(scoreFile, project: p.id))
        try JSONEncoder().encode(p).write(to: LocalStore.file("project.json", project: p.id))
        XCTAssertEqual(LocalStore.load().first {$0.id == p.id}?.scores, p.scores)
    }
    @MainActor func testWholeVideoModeCanBeUndoneWithoutLosingPreviousCuts() async throws {
        var p = LocalProject(name: "whole", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(p.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        try Data([0]).write(to: LocalStore.file(p.source, project: p.id))
        p.duration = 10; p.analyzed = true; p.edit.clips = [Clip(start: 2, end: 5)]
        let model = EditorModel(); model.project = p; model.edit = p.edit; model.wholeVideo = true
        model.applyWholeVideo()
        XCTAssertEqual(model.edit.clips.first?.start, 0)
        XCTAssertEqual(model.edit.clips.first?.end, 10)
        model.undo()
        XCTAssertEqual(model.edit.clips, p.edit.clips)
        XCTAssertFalse(model.wholeVideo)
        let saved = await model.save(); XCTAssertTrue(saved)
    }
    @MainActor func testRenameNamesTheProjectAndIgnoresABlankName() async throws {
        var p = LocalProject(name: "Video 1", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(p.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        try Data([0]).write(to: LocalStore.file(p.source, project: p.id))
        p.duration = 10; p.analyzed = true
        let model = EditorModel(); model.project = p; model.edit = p.edit
        model.rename("  Beach day  ")
        XCTAssertEqual(model.project?.name, "Beach day")
        XCTAssertEqual(model.projects.first?.name, "Beach day")
        model.rename("   ")
        XCTAssertEqual(model.project?.name, "Beach day")
        await model.settleSaves()
    }
    func testTemporaryCleanupPreservesSourceAndReferencedExports() async throws {
        var p = LocalProject(name: "cleanup", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(p.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        p.exports = [LocalExport(file: "RK-Motion-keep.mp4", duration: 1)]
        for name in [p.source, "RK-Motion-keep.mp4", "RK-Motion-orphan.mp4"] {
            try Data([0, 1]).write(to: LocalStore.file(name, project: p.id))
        }
        try LocalStore.save(p)
        _ = try await LocalStore.cleanTemporaryFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalStore.file(p.source, project: p.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: LocalStore.file("RK-Motion-keep.mp4", project: p.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: LocalStore.file("RK-Motion-orphan.mp4", project: p.id).path))
    }
    @MainActor func testSaveFailureIsVisibleAndBackgroundGPUIsOptIn() async throws {
        let p = LocalProject(name: "save failure", source: "source.mov")
        // A regular file in place of the project directory forces a real I/O error.
        try Data([0]).write(to: LocalStore.folder(p.id))
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(p.id))}
        let model = EditorModel(); model.project = p
        let saved = await model.save()
        XCTAssertFalse(saved); XCTAssertTrue(model.saveFailed)
        XCTAssertFalse(ContinuedProcessing.shared.enabled, "CI/personal builds must not require a paid GPU entitlement")
    }

}
