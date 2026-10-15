import XCTest
import AVFoundation
@testable import RKMotion

/// F06: beat sync keeps whole videos whole, never repeats footage, and the
/// length the export step shows is the length the export makes.
final class BeatPolicyTests: XCTestCase {
    /// Adjacent clips along the source: growing the first to the nearer
    /// later beat would play the start of the second twice.
    func testACutNeverGrowsIntoTheNextClipsFootage() {
        let clips = [Clip(start: 0, end: 4), Clip(start: 4, end: 8)]
        let synced = Beats.synced(clips, beats: [0, 1, 2, 3, 4.3, 5.3, 6.3, 7.3, 8.3], speed: 1, transition: 0, sourceDuration: 20)
        XCTAssertLessThanOrEqual(synced[0].end, synced[1].start, "No moment may play twice")
        XCTAssertEqual(synced[0].end, 3, accuracy: 0.001, "With no room to grow, the cut moves back to the earlier beat")
        XCTAssertEqual(synced.map(\.start), clips.map(\.start), "Starts never move")
    }
    func testClipsTheRiderOverlappedOnlyShrink() {
        let clips = [Clip(start: 0, end: 5), Clip(start: 4, end: 9)]
        let synced = Beats.synced(clips, beats: stride(from: 0.0, through: 12, by: 0.8).map {$0}, speed: 1, transition: 0, sourceDuration: 20)
        XCTAssertLessThanOrEqual(synced[0].end, clips[0].end)
        XCTAssertLessThanOrEqual(synced[1].end, clips[1].end)
    }
    func testAClipOutOfSourceOrderStillGrowsIntoFreeFootage() {
        // The second clip comes first in the source: the first may grow into
        // the free footage after it, up to the source's end.
        let clips = [Clip(start: 10, end: 14), Clip(start: 0, end: 4)]
        let synced = Beats.synced(clips, beats: [0, 3.5, 4.3, 8], speed: 1, transition: 0, sourceDuration: 20)
        XCTAssertEqual(synced[0].end, 14.3, accuracy: 0.001)
    }
    func testAWholeVideoIsNeverCutToTheBeat() {
        var project = LocalProject(name: "whole", source: "source.mov")
        project.music = [LocalMusic(file: "song.wav", name: "song", duration: 60)]
        var edit = Edit(clips: [Clip(start: 0, end: 30)])
        XCTAssertTrue(LocalEngine.syncsToBeat(edit, project: project))
        edit.settings["wholeVideo"] = .flag(true)
        XCTAssertFalse(LocalEngine.syncsToBeat(edit, project: project))
        edit.settings["wholeVideo"] = nil; project.wholeVideo = true
        XCTAssertFalse(LocalEngine.syncsToBeat(edit, project: project), "An older edit without the setting follows the project")
        project.wholeVideo = false; edit.settings["beatSync"] = .flag(false)
        XCTAssertFalse(LocalEngine.syncsToBeat(edit, project: project))
    }

    /// End to end on a real ride and a song with a clear beat: the whole
    /// video keeps its length; an edit is moved onto the beat, and the
    /// length planned for the export screen is the exported file's length.
    func testThePlannedLengthIsTheExportedLength() async throws {
        var project = LocalProject(name: "beats", source: "source.mov")
        let folder = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        try await UITestFixture.makeRide(LocalStore.file(project.source, project: project.id), seconds: 4, width: 160, height: 120)
        try makeClicks(LocalStore.file("clicks.wav", project: project.id), seconds: 20, phase: 0.23)
        project.duration = try await AVURLAsset(url: LocalStore.file(project.source, project: project.id)).load(.duration).seconds
        project.analyzed = true
        project.music = [LocalMusic(file: "clicks.wav", name: "clicks", duration: 20)]
        let engine = LocalEngine()

        var whole = Edit(clips: [Clip(start: 0, end: project.duration)])
        whole.settings["wholeVideo"] = .flag(true)
        let wholeLength = await engine.plannedLength(project, edit: whole)
        XCTAssertEqual(try XCTUnwrap(wholeLength), project.duration, accuracy: 0.01, "The whole video keeps its own end")

        let edit = Edit(clips: [Clip(start: 0, end: 1.9), Clip(start: 2.2, end: 3.95)])
        let naive = LocalEngine.timeline(clips: edit.clips, speed: 1, transition: 0).last!.end
        let plannedLength = await engine.plannedLength(project, edit: edit)
        let planned = try XCTUnwrap(plannedLength)
        XCTAssertGreaterThan(abs(planned - naive), 0.05, "The clicks fall off the naive cuts, so beat sync must move them")
        let output = folder.appendingPathComponent("beats.mp4")
        let exported = try await engine.export(project, edit: edit, output: output) {_, _ in}
        XCTAssertEqual(exported, planned, accuracy: 0.001)
        let actual = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(actual, planned, accuracy: 0.1)

        // The model shows that planned length on the export screen.
        let model = await EditorModel()
        await MainActor.run {model.project = project; model.edit = edit}
        await model.settlePlan()
        let shown = await model.movieDuration, changed = await model.beatChangesLength
        XCTAssertEqual(try XCTUnwrap(shown), planned, accuracy: 0.001)
        XCTAssertTrue(changed)
    }
    /// 8 kHz clicks, two a second starting at `phase`, over a quiet hum.
    private func makeClicks(_ url: URL, seconds: Int, phase: Double) throws {
        var data = Data()
        func text(_ s: String) {data.append(contentsOf: s.utf8)}
        func word(_ n: UInt16) {data.append(UInt8(n & 255)); data.append(UInt8(n >> 8))}
        func long(_ n: UInt32) {word(UInt16(n & 65535)); word(UInt16(n >> 16))}
        let rate = 8000, samples = seconds * rate
        text("RIFF"); long(UInt32(36 + samples * 2)); text("WAVEfmt "); long(16); word(1); word(1); long(UInt32(rate)); long(UInt32(rate * 2)); word(2); word(16)
        text("data"); long(UInt32(samples * 2))
        for i in 0..<samples {
            let t = Double(i) / Double(rate)
            let since = (t - phase).truncatingRemainder(dividingBy: 0.5)
            let click = t >= phase && since >= 0 && since < 0.03 ? 20000.0 * exp(-since * 120) : 0
            word(UInt16(bitPattern: Int16(max(-32000, min(32000, click * sin(t * 2 * .pi * 1000) + 300 * sin(t * 2 * .pi * 110))))))
        }
        try data.write(to: url)
    }
}
