import XCTest
import AVFoundation
@testable import RKMotion

/// F01: one AVPlayerItem must never reach two players.
@MainActor final class PreviewPlaybackTests: XCTestCase {
    private func preview() -> PreviewEdit {
        PreviewEdit(composition: AVMutableComposition(), video: AVMutableVideoComposition(), audio: AVMutableAudioMix())
    }
    func testTappingEditAgainKeepsTheSameItemOnTheSamePlayer() {
        let playback = PreviewPlayback(), edit = preview()
        let player = playback.player
        playback.showEdit(edit)
        let first = playback.player.currentItem
        XCTAssertNotNil(first)
        for _ in 0..<5 {playback.showEdit(edit)}
        XCTAssertTrue(playback.player === player, "The step keeps one player")
        XCTAssertTrue(playback.player.currentItem === first, "A repeated tap must not swap the item")
        XCTAssertTrue(playback.showingEdit)
    }
    func testSwitchingBackAndForthMakesAFreshItemEachTime() {
        let playback = PreviewPlayback(), edit = preview()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("absent.mov")
        var seen: [AVPlayerItem] = []
        for _ in 0..<4 {
            playback.showEdit(edit); seen.append(playback.player.currentItem!)
            playback.showSource(source); seen.append(playback.player.currentItem!)
        }
        XCTAssertEqual(Set(seen.map(ObjectIdentifier.init)).count, seen.count, "No item is put back on a player")
        XCTAssertFalse(playback.showingEdit)
    }
    /// Coming back to the edit step makes a new screen with its own player
    /// while the old one may still be alive. The old code put the model's one
    /// item on both, which AVFoundation answers with an exception.
    func testTwoScreensShowingOneEditNeverShareAnItem() {
        let edit = preview()
        let leaving = PreviewPlayback(), arriving = PreviewPlayback()
        leaving.showEdit(edit); arriving.showEdit(edit, play: false)
        XCTAssertNotNil(leaving.player.currentItem); XCTAssertNotNil(arriving.player.currentItem)
        XCTAssertFalse(leaving.player.currentItem === arriving.player.currentItem)
    }
}
