import AVFoundation
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
    func testSongEndsWhereItsAudioEnds() async throws {
        // Laid out like YouTube's audio: every sample sits in fragments while
        // the header already states the whole 3 s, which AVFoundation counts
        // twice. Run before the fix, the picker showed double the song.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer {try? FileManager.default.removeItem(at: file)}
        try XCTUnwrap(Data(base64Encoded: Self.youTubeLayout.joined())).write(to: file)
        let before = try await AVURLAsset(url: file).load(.duration).seconds
        let fixture = AVURLAsset(url: file)
        let fixtureTracks = try await fixture.loadTracks(withMediaType: .audio)
        let music = try YouTubeMusic.audioLength(fixture, track: try XCTUnwrap(fixtureTracks.first)).seconds
        print("YouTube-layout fixture reads as \(before) s; its music lasts \(music) s")
        XCTAssertGreaterThan(before, 5, "the fixture no longer shows the doubled length")
        XCTAssertEqual(music, 3.05, accuracy: 0.1)
        try await YouTubeMusic.trimToAudio(file)
        let asset = AVURLAsset(url: file)
        let after = try await asset.load(.duration).seconds
        // The copy re-applies AAC's encoder delay, a few hundredths of a
        // second at each end, so it may come out slightly shorter than the
        // samples' own count.
        XCTAssertEqual(after, music, accuracy: 0.25, "read as \(before) s before the repair")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        // A song that already ends with its audio is left alone.
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        try await YouTubeMusic.trimToAudio(file)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size)
    }
    /// 3 s of a 440 Hz tone, AAC in a fragmented MP4 like YouTube's itag 140.
    private static let youTubeLayout = [
        "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",
    ]
}
