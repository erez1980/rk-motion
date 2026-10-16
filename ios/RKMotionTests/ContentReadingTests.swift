import XCTest
@testable import RKMotion

final class ContentReadingTests: XCTestCase {
    private func signals(seconds: Int = 20, motion: Double, music: Double = 0, speech: Double = 0, cheerEvery: Int = 0,
                         people: Double = 0, scenes: [String: Double] = [:]) -> Signals {
        Signals(motion: (0..<seconds).map {motion + Double($0 % 3) * 0.002},
                loudness: (0..<seconds).map {0.1 + Double($0 % 4) * 0.05},
                music: Array(repeating: music, count: seconds), speech: Array(repeating: speech, count: seconds),
                cheer: (0..<seconds).map {cheerEvery > 0 && $0 % cheerEvery == 0 ? 0.8 : 0},
                people: Array(repeating: people, count: seconds), scenes: scenes)
    }
    func testActionKeepsTheRideFormula() {
        let s = signals(motion: 0.1)
        let m = LocalEngine.normalized(s.motion), a = LocalEngine.normalized(s.loudness)
        let scores = s.scores(for: .action)
        for index in scores.indices {XCTAssertEqual(scores[index], 0.65 * m[index] + 0.35 * a[index], accuracy: 1e-9)}
    }
    func testUnmeasuredChannelsDoNotSinkScores() {
        var s = signals(motion: 0.1)
        s.music = []; s.cheer = []; s.people = []
        // Only motion is left of the party recipe, so it carries the whole score.
        for (score, motion) in zip(s.scores(for: .party), LocalEngine.normalized(s.motion)) {XCTAssertEqual(score, motion, accuracy: 1e-9)}
    }
    func testReadsAParty() {
        let reading = ContentReading.read(signals(motion: 0.05, music: 0.9, cheerEvery: 5, people: 4, scenes: ["party": 0.4]))
        XCTAssertEqual(reading.detected, .party)
        XCTAssertEqual(reading.kind, .party)
        XCTAssertTrue(reading.kind.mutesOriginal)
        XCTAssertTrue(reading.facts.contains {$0.contains("100")}, "The music share is one of the reasons: \(reading.facts)")
    }
    func testReadsATalk() {
        XCTAssertEqual(ContentReading.read(signals(motion: 0.012, speech: 0.9, people: 1)).detected, .talk)
    }
    func testReadsARide() {
        let reading = ContentReading.read(signals(motion: 0.12, scenes: ["outdoor": 0.8, "bicycle": 0.5]))
        XCTAssertEqual(reading.detected, .action)
        XCTAssertFalse(reading.kind.mutesOriginal)
    }
    func testQuietStillVideoIsGeneral() {
        XCTAssertEqual(ContentReading.read(signals(motion: 0.01)).detected, .general)
    }
    func testSoundLabelsMapToChannels() {
        XCTAssertEqual(SoundTally.channel("music"), .music)
        XCTAssertEqual(SoundTally.channel("speech"), .speech)
        XCTAssertEqual(SoundTally.channel("belly_laugh"), .cheer)
        XCTAssertEqual(SoundTally.channel("applause"), .cheer)
        XCTAssertNil(SoundTally.channel("wind"))
    }
    func testReadingAndSignalsSurviveARestart() throws {
        var project = LocalProject(name: "party", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(project.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(project.id))}
        try Data([0]).write(to: LocalStore.file(project.source, project: project.id))
        let s = signals(motion: 0.05, music: 0.9, people: 3)
        project.reading = ContentReading.read(s)
        try LocalStore.writeSignals(s, project: project.id)
        try LocalStore.save(project)
        let restored = try XCTUnwrap(LocalStore.load().first {$0.id == project.id})
        XCTAssertEqual(restored.reading, project.reading)
        XCTAssertEqual(LocalStore.readSignals(project: project.id), s)
    }
}
