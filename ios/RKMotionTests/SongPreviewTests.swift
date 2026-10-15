import XCTest
@testable import RKMotion

/// Listening to a YouTube search result before adding it.
@MainActor final class SongPreviewTests: XCTestCase {
    private let link = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let audio = FileManager.default.temporaryDirectory.appendingPathComponent("listen.m4a")

    private func settle(_ preview: SongPreview, until done: @escaping () -> Bool) async {
        for _ in 0..<200 where !done() {try? await Task.sleep(for: .milliseconds(10))}
    }
    func testATapPlaysTheSongAndASecondTapStopsIt() async {
        let audio = audio
        let preview = SongPreview {_ in audio}
        preview.toggle("abc", link: link)
        XCTAssertEqual(preview.loading, "abc")
        await settle(preview) {preview.playing != nil}
        XCTAssertEqual(preview.playing, "abc"); XCTAssertNil(preview.loading)
        preview.toggle("abc", link: link)
        XCTAssertNil(preview.playing)
    }
    func testAnotherSongReplacesTheOnePlaying() async {
        let audio = audio
        let preview = SongPreview {_ in audio}
        preview.toggle("abc", link: link)
        await settle(preview) {preview.playing != nil}
        preview.toggle("def", link: link)
        await settle(preview) {preview.playing == "def"}
        XCTAssertEqual(preview.playing, "def")
    }
    func testASongThatCannotBeReachedSaysSo() async {
        let preview = SongPreview {_ in throw URLError(.notConnectedToInternet)}
        preview.toggle("abc", link: link)
        await settle(preview) {preview.failure != nil}
        XCTAssertNotNil(preview.failure); XCTAssertNil(preview.playing); XCTAssertNil(preview.loading)
    }
}
