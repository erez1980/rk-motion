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
    func testAutoPickMeasuresTheMovieWithItsTransitions() {
        // Each one-second dissolve takes a second off the movie, so eight
        // 4-second clips would make 25 seconds, not the 30 asked for.
        let clips = (0..<12).map {clip(Double($0) * 10, Double($0) * 10 + 4, 1 - Double($0) / 100)}
        let picked = ClipPicker.autoPick(clips, seconds: 30, speed: 1, transition: 1).filter {$0.selected != false}
        let length = LocalEngine.timeline(clips: picked, speed: 1, transition: 1).last?.end ?? 0
        XCTAssertEqual(picked.count, 10)
        XCTAssertGreaterThanOrEqual(length, 30)
        XCTAssertLessThanOrEqual(length, 36)
        // Speed shortens the movie the same way: at double speed twice the footage is needed.
        let fast = ClipPicker.autoPick(clips, seconds: 12, speed: 2, transition: 0).filter {$0.selected != false}
        XCTAssertEqual(fast.count, 6)
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
    /// A new movie aims at 45 seconds; "all" keeps every suggested moment.
    @MainActor func testTheMovieLengthChoosesTheClipsAgain() {
        let clips = (0..<12).map {clip(Double($0) * 20, Double($0) * 20 + 10, 0.5 + Double($0 % 5) * 0.1)}
        let model = EditorModel()
        let fitted = model.fittedToLength(clips, settings: [:])
        let length = fitted.filter {$0.selected != false}.reduce(0) {$0 + $1.duration}
        XCTAssertEqual(model.targetLength, Edit.defaultLength)
        XCTAssertGreaterThanOrEqual(length, 45); XCTAssertLessThanOrEqual(length, 54)
        model.edit.clips = fitted
        model.pickLength("all")
        XCTAssertTrue(model.edit.clips.allSatisfy {$0.selected != false})
        XCTAssertEqual(model.targetLength, "all")
        model.pickLength("30")
        XCTAssertLessThanOrEqual(model.edit.clips.filter {$0.selected != false}.reduce(0) {$0 + $1.duration}, 36)
    }
}
