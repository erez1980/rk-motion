import XCTest
import AVFoundation
@testable import RKMotion

final class EffectsTests: XCTestCase {
    func testRampPlaysFastIntoAndOutOfTheSlowMotion() {
        var clip = Clip(start: 0, end: 6, slowAt: 2)
        clip.ramp = true
        let parts = clip.stretches
        XCTAssertEqual(parts.map(\.factor), [1, Clip.rampFactor, Clip.slowFactor, Clip.rampFactor, 1])
        XCTAssertEqual(parts[1].start, 2 - Clip.rampSpan, accuracy: 1e-9)
        XCTAssertEqual(parts[3].end, 3.5 + Clip.rampSpan, accuracy: 1e-9)
        // 6 s of footage: 1.5 s slowed twice adds 1.5, two 0.8 s ramps at double speed take 0.8 off.
        XCTAssertEqual(clip.shown(1), 6 + 1.5 - 0.8, accuracy: 1e-9)
        for second in stride(from: 0.0, through: 6, by: 0.1) {
            XCTAssertEqual(clip.footage(atScreen: clip.screenOffset(of: second, speed: 1.5), speed: 1.5), second, accuracy: 1e-6)
        }
        // Without slow motion there is nothing to ramp into.
        var plain = Clip(start: 0, end: 6); plain.ramp = true
        XCTAssertEqual(plain.shown(1), 6, accuracy: 1e-9)
    }
    func testHookOpensWithThePeak() {
        let scores = [0.1, 0.2, 0.3, 0.2, 0.1, 0.9, 0.4, 0.1, 0.1, 0.1]
        let clips = [Clip(start: 0, end: 4), Clip(start: 4, end: 8)]
        let hooked = Hook.added(clips, scores: scores, settings: ["hook": .flag(true)])
        XCTAssertEqual(hooked.count, 3)
        XCTAssertEqual(hooked[0].start, 4.5, accuracy: 1e-9)
        XCTAssertEqual(hooked[0].end, 6.5, accuracy: 1e-9)
        XCTAssertEqual(Array(hooked.dropFirst()), clips)
        XCTAssertEqual(Hook.added(clips, scores: scores, settings: [:]), clips)
        XCTAssertEqual(Hook.added(clips, scores: scores, settings: ["hook": .flag(true), "wholeVideo": .flag(true)]), clips)
        XCTAssertEqual(Hook.added([clips[0]], scores: scores, settings: ["hook": .flag(true)]).count, 1)
        // The length picker counts the hook.
        let shaped = MovieShape.shaped(clips, scores: scores, settings: ["hook": .flag(true)])
        XCTAssertEqual(LocalEngine.timeline(clips: shaped, speed: 1, transition: 0).last?.end ?? 0, 10, accuracy: 1e-9)
    }
    func testPunchesLandOnEveryOtherBeat() {
        let beats = stride(from: 0.0, to: 10, by: 0.5).map {$0}
        let punches = BeatPunch.times(beats, length: 10)
        XCTAssertEqual(punches.first, 1)
        XCTAssertTrue(zip(punches, punches.dropFirst()).allSatisfy {$1 - $0 >= BeatPunch.gap})
        XCTAssertTrue(punches.allSatisfy {$0 <= 9})
    }
    func testWhooshSitsOnTheSeams() throws {
        XCTAssertEqual(Whoosh.places(seams: [3, 3.2, 8, 9.9], length: 10), [3 - Whoosh.seconds / 2, 8 - Whoosh.seconds / 2])
        let sound = Whoosh.samples()
        XCTAssertEqual(sound.count, Int(Whoosh.seconds * Whoosh.rate))
        XCTAssertEqual(Double(sound.map(abs).max() ?? 0), 0.9, accuracy: 0.001)
        // Quiet at both ends, loud in the middle.
        XCTAssertLessThan(abs(sound[10]), 0.05)
        let url = try Whoosh.file()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testBlurredAndDarkSecondsSink() {
        let sharp: [UInt8] = (0..<(16 * 8)).map {UInt8(($0 % 2) * 200 + 20)}
        let flat = [UInt8](repeating: 120, count: 16 * 8)
        XCTAssertGreaterThan(LocalEngine.clarity(sharp, width: 16).sharpness, 0.3)
        XCTAssertEqual(LocalEngine.clarity(flat, width: 16).sharpness, 0)
        XCTAssertEqual(LocalEngine.clarity(flat, width: 16).brightness, 120.0 / 255, accuracy: 1e-9)
        var signals = Signals(motion: [0.02, 0.05, 0.08, 0.03, 0.06, 0.04], loudness: [0.1, 0.3, 0.4, 0.2, 0.3, 0.2])
        signals.sharpness = [0.2, 0.2, 0.05, 0.2, 0.2, 0.2]
        signals.brightness = [0.5, 0.5, 0.5, 0.5, 0.01, 0.5]
        XCTAssertEqual(signals.poor, [false, false, true, false, true, false])
        XCTAssertEqual(signals.poorShare, 2.0 / 6, accuracy: 1e-9)
        var clean = signals; clean.sharpness = nil; clean.brightness = nil
        let kept = clean.scores(for: .general), sunk = signals.scores(for: .general)
        XCTAssertGreaterThan(kept[2], 0.5)
        XCTAssertEqual(sunk[2], kept[2] * 0.35, accuracy: 1e-9)
        XCTAssertEqual(sunk[0], kept[0], accuracy: 1e-9)
    }
}
