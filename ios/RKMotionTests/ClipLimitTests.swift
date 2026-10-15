import XCTest
@testable import RKMotion

/// F07: the suggestions, the editor and the engine agree on one clip limit.
@MainActor final class ClipLimitTests: XCTestCase {
    /// A full day of riding: a burst of activity every minute. The old
    /// suggestions chose every one of ~1,440 clips, which the editor allowed
    /// and the engine then refused at export with a generic message.
    private func longRide() -> (scores: [Double], duration: Double) {
        let duration = 24.0 * 3600
        var scores = [Double](repeating: 0, count: Int(duration))
        for second in stride(from: 10, to: scores.count, by: 60) {scores[second] = 0.6 + Double(second % 7) * 0.05}
        return (scores, duration)
    }
    func testLongRideSuggestionsChooseNoMoreThanTheLimit() {
        let ride = longRide()
        let clips = LocalEngine.ranges(scores: ride.scores, duration: ride.duration)
        XCTAssertGreaterThan(clips.count, Edit.clipLimit, "Every suggestion stays listed")
        XCTAssertEqual(clips.filter {$0.selected != false}.count, Edit.clipLimit)
        let chosen = clips.filter {$0.selected != false}.compactMap(\.score), skipped = clips.filter {$0.selected == false}.compactMap(\.score)
        XCTAssertGreaterThanOrEqual(chosen.min() ?? 0, skipped.max() ?? 1, "The strongest are the ones chosen")
        XCTAssertEqual(clips.map(\.start), clips.map(\.start).sorted(), "Order stays chronological")
    }
    func testTheEditorNamesTheLimitBeforeExport() {
        var p = LocalProject(name: "limit", source: "source.mov"); p.duration = 10_000; p.analyzed = true
        let model = EditorModel(); model.project = p
        model.edit.clips = (0..<Edit.clipLimit).map {Clip(start: Double($0) * 10, end: Double($0) * 10 + 5)}
        XCTAssertNil(model.editValidationMessage)
        model.edit.clips.append(Clip(start: 9_990, end: 9_995))
        let problem = try? XCTUnwrap(model.editValidationMessage)
        XCTAssertTrue(problem?.contains("\(Edit.clipLimit)") == true, problem ?? "no message")
        model.edit.clips[0].selected = false
        XCTAssertNil(model.editValidationMessage, "Only chosen clips count")
    }
}
