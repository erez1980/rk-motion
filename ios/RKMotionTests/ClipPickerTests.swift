import XCTest
@testable import RKMotion

final class ClipPickerTests: XCTestCase {
    private func clip(_ start: Double, _ end: Double, _ score: Double?) -> Clip {
        var clip = Clip(start: start, end: end); clip.score = score; return clip
    }
    func testAutoPickTakesTheStrongestClipsThatFitAndKeepsTheOrder() {
        let clips = [clip(0, 20, 0.5), clip(30, 50, 0.9), clip(60, 90, 0.8), clip(100, 120, 0.7)]
        let picked = ClipPicker.autoPick(clips, seconds: 45)
        // 0.9 (20s) then 0.8 (30s) would be 50s: within a fifth over 45, so it is taken.
        XCTAssertEqual(picked.map {$0.selected != false}, [false, true, true, false])
        XCTAssertEqual(picked.map(\.id), clips.map(\.id))
    }
    func testAutoPickSkipsAClipThatWouldOverrunAndTriesTheNext() {
        let clips = [clip(0, 20, 0.9), clip(30, 70, 0.8), clip(80, 90, 0.7)]
        XCTAssertEqual(ClipPicker.autoPick(clips, seconds: 30).map {$0.selected != false}, [true, false, true])
    }
    func testAutoPickKeepsTheBestClipWhenEveryClipIsTooLong() {
        let clips = [clip(0, 100, 0.4), clip(100, 200, 0.6)]
        XCTAssertEqual(ClipPicker.autoPick(clips, seconds: 30).map {$0.selected != false}, [false, true])
    }
    func testShuffleAlwaysChangesTheOrderAndKeepsEveryClip() {
        var generator = SystemRandomNumberGenerator()
        let clips = [clip(0, 1, nil), clip(2, 3, nil)]
        for _ in 0..<20 {
            let result = ClipPicker.shuffled(clips, using: &generator)
            XCTAssertNotEqual(result.map(\.id), clips.map(\.id))
            XCTAssertEqual(Set(result.map(\.id)), Set(clips.map(\.id)))
        }
        XCTAssertEqual(ClipPicker.shuffled([clips[0]], using: &generator), [clips[0]])
    }
}
