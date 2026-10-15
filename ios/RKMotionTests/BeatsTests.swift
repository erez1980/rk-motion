import XCTest
@testable import RKMotion

final class BeatsTests: XCTestCase {
    /// An onset envelope with a hit every `period` seconds from `phase`.
    private func hits(period: Double, phase: Double, seconds: Double) -> [Double] {
        var onsets = [Double](repeating: 0, count: Int(seconds * Beats.rate))
        var time = phase
        while Int((time * Beats.rate).rounded()) < onsets.count {onsets[Int((time * Beats.rate).rounded())] = 1; time += period}
        return onsets
    }
    func testFindsTempoAndWhereTheBeatFalls() throws {
        let grid = try XCTUnwrap(Beats.grid(hits(period: 0.5, phase: 0.13, seconds: 20)))
        XCTAssertEqual(grid.period, 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(grid.times.first), 0.13, accuracy: 0.02)
    }
    func testReadsAFastSongAtItsOwnSpeed() throws {
        // 128 BPM must not come back as half or double time.
        let grid = try XCTUnwrap(Beats.grid(hits(period: 60 / 128, phase: 0.05, seconds: 30)))
        XCTAssertEqual(grid.period, 60 / 128, accuracy: 0.01)
    }
    func testSilenceHasNoBeat() {
        XCTAssertNil(Beats.grid([Double](repeating: 0, count: 2000)))
    }
    func testARiseInLoudnessIsAnOnset() {
        let onsets = Beats.onsets([Double](repeating: 0.001, count: 50) + [Double](repeating: 0.5, count: 50))
        XCTAssertEqual(onsets.indices.max(by: {onsets[$0] < onsets[$1]}), 50)
    }

    func testHearsTheBeatOfARealFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let file = folder.appendingPathComponent("clicks.wav")
        try clickTrack(file, seconds: 12, period: 0.5, phase: 0.25)
        let whole = try await Beats.envelope(file, from: 0, length: 12)
        let grid = try XCTUnwrap(Beats.grid(whole))
        XCTAssertEqual(grid.period, 0.5, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(grid.times.first), 0.25, accuracy: 0.03)
        // Read from a song's chosen start, beats count from that start.
        let tail = try await Beats.envelope(file, from: 1.1, length: 10)
        let later = try XCTUnwrap(Beats.grid(tail))
        XCTAssertEqual(try XCTUnwrap(later.times.first), 0.15, accuracy: 0.03)
    }
    /// 8 kHz mono, a short 1 kHz burst on every beat and silence between.
    private func clickTrack(_ url: URL, seconds: Double, period: Double, phase: Double) throws {
        let samples = Int(seconds * 8000)
        var data = Data()
        func text(_ s: String) {data.append(contentsOf: s.utf8)}
        func word(_ n: UInt16) {data.append(UInt8(n & 255)); data.append(UInt8(n >> 8))}
        func long(_ n: UInt32) {word(UInt16(n & 65535)); word(UInt16(n >> 16))}
        text("RIFF"); long(UInt32(36 + samples * 2)); text("WAVEfmt "); long(16); word(1); word(1); long(8000); long(16000); word(2); word(16)
        text("data"); long(UInt32(samples * 2))
        for i in 0..<samples {
            let time = Double(i) / 8000
            let sinceBeat = (time - phase).truncatingRemainder(dividingBy: period)
            let loud = time >= phase && sinceBeat >= 0 && sinceBeat < 0.02
            word(UInt16(bitPattern: Int16(loud ? sin(time * 2 * .pi * 1000) * 12000 : 0)))
        }
        try data.write(to: url)
    }

    private func cuts(_ clips: [Clip], speed: Double, transition: Double) -> [Double] {
        let segments = LocalEngine.timeline(clips: clips, speed: speed, transition: transition)
        return segments.indices.map {$0 + 1 < segments.count ? segments[$0 + 1].start + segments[$0 + 1].incoming / 2 : segments[$0].end}
    }
    private func onBeat(_ time: Double, _ beats: [Double]) -> Bool {beats.contains {abs($0 - time) < 0.01}}

    func testEveryCutLandsOnABeat() {
        let beats = stride(from: 0.2, to: 60, by: 0.5).map {$0}
        let clips = [Clip(start: 0, end: 10), Clip(start: 20, end: 30.3), Clip(start: 40, end: 47.9)]
        for (speed, transition) in [(1.0, 0.0), (1.5, 0.0), (1.0, 0.5), (2.0, 1.0)] {
            let synced = Beats.synced(clips, beats: beats, speed: speed, transition: transition, sourceDuration: 100)
            for cut in cuts(synced, speed: speed, transition: transition) {
                XCTAssertTrue(onBeat(cut, beats), "cut at \(cut) for speed \(speed), transition \(transition)")
            }
            // Only the ends move; each clip still starts where it was cut.
            XCTAssertEqual(synced.map(\.start), clips.map(\.start))
        }
    }
    func testNeverRunsPastTheEndOfTheVideo() {
        // The later beat would need footage the source does not have.
        let synced = Beats.synced([Clip(start: 0, end: 10)], beats: [0, 9.7, 10.2], speed: 1, transition: 0, sourceDuration: 10)
        XCTAssertEqual(synced[0].end, 9.7, accuracy: 0.001)
    }
    func testCutsAfterTheSongAreLeftAlone() {
        let clips = [Clip(start: 0, end: 5), Clip(start: 10, end: 15)]
        let synced = Beats.synced(clips, beats: [0, 0.5, 1, 1.5], speed: 1, transition: 0, sourceDuration: 100)
        XCTAssertEqual(synced, clips)
    }
}
