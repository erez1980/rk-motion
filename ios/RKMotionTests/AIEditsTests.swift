import XCTest
import CoreImage
@testable import RKMotion

final class AIEditsTests: XCTestCase {
    func testSlowMotionStretchesItsPartOfTheClip() {
        let clip = Clip(start: 10, end: 14, slowAt: 11)
        XCTAssertEqual(clip.slowRange?.start, 11)
        XCTAssertEqual(clip.slowRange?.end, 12.5)
        XCTAssertEqual(clip.shown(1), 5.5, accuracy: 1e-9)
        XCTAssertEqual(clip.shown(2), 2.75, accuracy: 1e-9)
        XCTAssertEqual(clip.screenOffset(of: 11, speed: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(clip.screenOffset(of: 11.75, speed: 1), 2.5, accuracy: 1e-9)
        XCTAssertEqual(clip.screenOffset(of: 12.5, speed: 1), 4, accuracy: 1e-9)
        XCTAssertEqual(clip.screenOffset(of: 14, speed: 1), clip.shown(1), accuracy: 1e-9)
        // Kept inside the clip, and left out when the clip is too short for it.
        XCTAssertEqual(Clip(start: 0, end: 2, slowAt: 1.9).slowRange?.start, 0.5)
        XCTAssertNil(Clip(start: 0, end: 1.9, slowAt: 0).slowRange)
        XCTAssertEqual(Clip(start: 0, end: 1.9, slowAt: 0).shown(1), 1.9, accuracy: 1e-9)
        // The timeline counts the slowed seconds.
        XCTAssertEqual(LocalEngine.timeline(clips: [Clip(start: 0, end: 2), clip], speed: 1, transition: 0).last?.end ?? 0, 7.5, accuracy: 1e-9)
    }
    func testSlowsTheStrongestMomentOnly() {
        let scores = [0.1, 0.2, 0.9, 0.3, 0.1, 0.5]
        let clips = [Clip(start: 0, end: 2, slowAt: 0.5), Clip(start: 2, end: 5)]
        let peak = Highlights.peak(clips, scores: scores)
        XCTAssertEqual(peak?.clip, 1)
        XCTAssertEqual(peak?.time, 2.5)
        let slowed = Highlights.slowed(clips, scores: scores)
        XCTAssertNil(slowed[0].slowAt)
        XCTAssertEqual(slowed[1].slowRange?.start, 2)
        XCTAssertEqual(Highlights.peakTime([Clip(start: 0, end: 2), Clip(start: 2, end: 5)], scores: scores, speed: 1, transition: 0) ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(Highlights.peakTime(slowed, scores: scores, speed: 1, transition: 0) ?? 0, 3, accuracy: 1e-9)
        XCTAssertNil(Highlights.peak(clips, scores: []))
    }
    func testFindsTheDropAndTheStartThatMeetsThePeak() {
        let song = Array(repeating: 0.2, count: 40) + Array(repeating: 0.5, count: 40) + Array(repeating: 0.9, count: 80)
        XCTAssertEqual(Drop.find(song, rate: 4) ?? 0, 20, accuracy: 0.01)
        XCTAssertNil(Drop.find(Array(repeating: 0.6, count: 200), rate: 4), "a flat song has no drop")
        XCTAssertNil(Drop.find([0.1, 0.9], rate: 4))
        XCTAssertEqual(Drop.start(drop: 20, peak: 5), 15)
        XCTAssertNil(Drop.start(drop: 3, peak: 5))
    }
    func testMusicGivesWayToVoicesAndCheers() {
        var speech = Array(repeating: 0.0, count: 16), cheer = speech
        speech[1] = 0.9; speech[2] = 0.9; cheer[11] = 0.8
        let clips = [Clip(start: 0, end: 4), Clip(start: 10, end: 14)]
        let segments = LocalEngine.timeline(clips: clips, speed: 1, transition: 0)
        let stretches = Ducking.intervals(clips: clips, segments: segments, speech: speech, cheer: cheer, speed: 1)
        XCTAssertEqual(stretches.map {$0.start}, [1, 5])
        XCTAssertEqual(stretches.map {$0.end}, [3, 6])
        let points = Ducking.envelope(stretches, volume: 1, length: 8)
        XCTAssertEqual(points.map {$0.time}, [0, 0.75, 1, 3, 3.25, 4.75, 5, 8])
        for (point, expected) in zip(points.map({$0.volume}), [1, 1, 0.35, 0.35, 1, 1, 0.35, 0] as [Float]) {XCTAssertEqual(point, expected, accuracy: 1e-5)}
        // With nobody heard, the song plays on and fades out at the end, as before.
        let plain = Ducking.envelope([], volume: 0.65, length: 8)
        XCTAssertEqual(plain.map {$0.time}, [0, 5, 8])
        XCTAssertEqual(plain.map {$0.volume}, [0.65, 0.65, 0])
    }
    func testFramesOnThePeople() {
        XCTAssertEqual(Framing.focus(of: Clip(start: 0, end: 5), in: [-1, 0.2, 0.3, -1, 0.8]), 0.3)
        XCTAssertNil(Framing.focus(of: Clip(start: 0, end: 5), in: nil))
        XCTAssertNil(Framing.focus(of: Clip(start: 0, end: 2), in: [-1, -1, 0.5]))
        XCTAssertEqual(Framing.shift(focus: nil, scaled: 300, width: 100), -100)
        XCTAssertEqual(Framing.shift(focus: 0.5, scaled: 300, width: 100), -100)
        XCTAssertEqual(Framing.shift(focus: 0, scaled: 300, width: 100), 0, "never shows past the left edge")
        XCTAssertEqual(Framing.shift(focus: 1, scaled: 300, width: 100), -200, "never shows past the right edge")
        XCTAssertEqual(Framing.shift(focus: 0.2, scaled: 100, width: 100), 0, "nothing to move when nothing is cut off")
    }
    func testJoinsWhereThePeopleStand() {
        let first = Signals(motion: [0.1, 0.1], loudness: [0.1, 0.1], focus: [0.2, 0.4])
        let second = Signals(motion: [0.1, 0.1], loudness: [0.1, 0.1])
        XCTAssertEqual(Signals.joined([(first, 0, 2), (second, 2, 2)]).focus, [0.2, 0.4, -1, -1])
        XCTAssertNil(Signals.joined([(second, 0, 2), (second, 2, 2)]).focus)
    }
    func testWarmGradeWarms() throws {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let graded = Look.apply(Look.grade(for: .party), to: gray)
        XCTAssertEqual(graded.extent, gray.extent)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(graded, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertGreaterThan(pixel[0], pixel[2], "red over blue: \(pixel)")
    }
    func testWordsForTheMovie() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for kind in ContentKind.allCases {
            let words = MovieWords.fallback(for: kind, date: date)
            XCTAssertFalse(words.title.isEmpty)
            XCTAssertFalse(words.subtitle.isEmpty)
            XCTAssertTrue(words.caption.contains("#"), "\(kind)")
        }
        let plain = MovieWords.fallback(for: .action, date: date)
        let words = MovieWords.parse("""
            TITLE: "Sunset Ride"
            CAPTION: Wheels up #ride #golan
            Something else
            """, fallback: plain)
        XCTAssertEqual(words.title, "Sunset Ride")
        XCTAssertEqual(words.subtitle, plain.subtitle)
        XCTAssertEqual(words.caption, "Wheels up #ride #golan")
    }
}
