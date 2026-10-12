import XCTest
@testable import RKMotion

/// Network extraction cannot run in CI: YouTube refuses data-centre clients,
/// so only the deterministic rules around it are tested here.
final class YouTubeMusicTests: XCTestCase {
    func testFindsTheLinkInsideSharedText() {
        XCTAssertEqual(YouTubeMusic.link(in: "Listen: https://youtu.be/dQw4w9WgXcQ?si=abc nice")?.host, "youtu.be")
        XCTAssertEqual(YouTubeMusic.link(in: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.host, "www.youtube.com")
        XCTAssertEqual(YouTubeMusic.link(in: "https://music.youtube.com/watch?v=x")?.host, "music.youtube.com")
        XCTAssertEqual(YouTubeMusic.link(in: "https://m.youtube.com/watch?v=x")?.host, "m.youtube.com")
    }
    func testRejectsHostsThatOnlyLookLikeYouTube() {
        // The app sends requests to whatever host passes, so lookalikes must not.
        XCTAssertNil(YouTubeMusic.link(in: "https://youtube.com.evil.example/watch?v=x"))
        XCTAssertNil(YouTubeMusic.link(in: "https://notyoutube.com/watch?v=x"))
        XCTAssertNil(YouTubeMusic.link(in: "https://example.com/youtube.com/watch?v=x"))
        XCTAssertNil(YouTubeMusic.link(in: "just some words, no link"))
    }
    func testShortRangedPieceIsNotTheEndWhenTheSizeIsKnown() {
        // The server may send less than a full chunk mid-file; stopping there
        // would save a truncated song.
        XCTAssertFalse(YouTubeMusic.finished(status: 206, received: 1_000, requested: 4_194_304, offset: 1_000, total: 9_000_000))
        XCTAssertTrue(YouTubeMusic.finished(status: 206, received: 1_000, requested: 4_194_304, offset: 9_000_000, total: 9_000_000))
        XCTAssertTrue(YouTubeMusic.finished(status: 206, received: 4_194_304, requested: 4_194_304, offset: 9_000_001, total: 9_000_000))
        // A full piece below the known size is not the end either.
        XCTAssertFalse(YouTubeMusic.finished(status: 206, received: 4_194_304, requested: 4_194_304, offset: 4_194_304, total: 9_000_000))
    }
    func testWithoutASizeOnlyAShortPieceOrAWholeFileEnds() {
        XCTAssertTrue(YouTubeMusic.finished(status: 200, received: 3_000_000, requested: 4_194_304, offset: 3_000_000, total: nil))
        XCTAssertTrue(YouTubeMusic.finished(status: 206, received: 10, requested: 4_194_304, offset: 4_194_314, total: nil))
        XCTAssertFalse(YouTubeMusic.finished(status: 206, received: 4_194_304, requested: 4_194_304, offset: 4_194_304, total: nil))
    }
    func testTitleBecomesASafeFileName() {
        XCTAssertEqual(YouTubeMusic.fileName(for: "AC/DC: Thunder?"), "AC DC Thunder.m4a")
        XCTAssertEqual(YouTubeMusic.fileName(for: "  spaced \n out\t title  "), "spaced out title.m4a")
        XCTAssertEqual(YouTubeMusic.fileName(for: "../../etc/passwd"), "etc passwd.m4a")
        XCTAssertEqual(YouTubeMusic.fileName(for: ""), "YouTube.m4a")
        XCTAssertEqual(YouTubeMusic.fileName(for: "..."), "YouTube.m4a")
        XCTAssertEqual(YouTubeMusic.fileName(for: String(repeating: "א", count: 200)), String(repeating: "א", count: 80) + ".m4a")
    }
}
