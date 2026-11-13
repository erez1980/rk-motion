import XCTest
import AVFoundation
import UIKit
@testable import RKMotion

/// The rider's own opening and closing: kept once, laid around the clips
/// with the edit's transitions, and the song running on under both.
final class BrandTests: XCTestCase {
    private var savedFolder: URL!
    private var savedDefaults: UserDefaults!
    private var folder: URL!
    private var suite = ""

    override func setUpWithError() throws {
        savedFolder = Brand.folder; savedDefaults = Brand.defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("brand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "brand-tests-\(UUID().uuidString)"
        Brand.folder = folder; Brand.defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        Brand.defaults.removePersistentDomain(forName: suite)
        Brand.folder = savedFolder; Brand.defaults = savedDefaults
        try? FileManager.default.removeItem(at: folder)
    }

    /// A square logo: lime on a transparent ground.
    private func logo() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image {context in
            UIColor(red: 0.78, green: 0.96, blue: 0.26, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 160))
        }.pngData()!
    }

    func testAChoiceIsKeptUntilRemoved() async throws {
        XCTAssertNil(Brand.asset(.intro))
        let first = try Brand.setImage(logo(), for: .intro)
        XCTAssertEqual(Brand.asset(.intro), first)
        XCTAssertEqual(first.seconds, Brand.imageSeconds)
        // A new choice replaces the old file.
        let second = try Brand.setImage(logo(), for: .intro)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Brand.url(first).path))
        XCTAssertEqual(Brand.asset(.intro), second)
        XCTAssertNil(Brand.shot(.intro, settings: ["brandIntro": .flag(false)]), "One movie can leave it out")
        XCTAssertEqual(Brand.shot(.intro, settings: [:]), second, "On by default")
        // A long video plays only its first seconds.
        let video = folder.appendingPathComponent("long.mov")
        try await UITestFixture.makeRide(video, seconds: 12, width: 160, height: 120)
        let outro = try await Brand.setVideo(video, for: .outro)
        XCTAssertEqual(outro.kind, .video)
        XCTAssertEqual(outro.seconds, Brand.longest, accuracy: 0.001)
        Brand.remove(.intro)
        XCTAssertNil(Brand.asset(.intro))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Brand.url(second).path))
    }

    func testTheOpeningAndClosingAreShotsOfTheirOwn() throws {
        let clips = [Clip(start: 0, end: 3.5), Clip(start: 4, end: 7.5)]
        let plain = LocalEngine.layout(clips: clips, speed: 1, transition: 0.5, settings: [:])
        XCTAssertEqual(plain.content, 0..<2)
        XCTAssertTrue(plain.endScreen)
        XCTAssertEqual(plain.length, 6.5 + Outro.added, accuracy: 0.0001)

        try Brand.setImage(logo(), for: .intro)
        try Brand.setImage(logo(), for: .outro)
        let branded = LocalEngine.layout(clips: clips, speed: 0.5, transition: 0.5, settings: [:])
        XCTAssertEqual(branded.segments.count, 4)
        XCTAssertEqual(branded.content, 1..<3)
        XCTAssertFalse(branded.endScreen, "The rider's closing takes the end screen's place")
        // Slow motion over the whole movie slows the clips, never the logo.
        XCTAssertEqual(branded.segments[0].duration, Brand.imageSeconds, accuracy: 0.0001)
        XCTAssertEqual(branded.segments[3].duration, Brand.imageSeconds, accuracy: 0.0001)
        XCTAssertEqual(branded.length, 2.5 + 7 + 7 + 2.5 - 3 * 0.5, accuracy: 0.0001)
        XCTAssertEqual(branded.contentStart, 2, accuracy: 0.0001)
        XCTAssertEqual(branded.segments[1].incoming, 0.5, accuracy: 0.0001, "The transition leads out of the opening")

        let without = LocalEngine.layout(clips: clips, speed: 1, transition: 0.5, settings: ["brandIntro": .flag(false), "brandOutro": .flag(false)])
        XCTAssertEqual(without.length, plain.length, accuracy: 0.0001)
        XCTAssertEqual(LocalEngine.layout(clips: clips, speed: 1, transition: 0.5, settings: [:], branded: false).segments.count, 2,
                       "The joined source never shows them")
        XCTAssertEqual(Brand.style(.intro, transition: SmartTransitions.name), "fade")
        XCTAssertEqual(Brand.style(.outro, transition: "slide"), "slide")
    }

    func testTheLogoIsFittedNotCropped() {
        let wide = Brand.placement(of: CGSize(width: 400, height: 100), in: CGSize(width: 1080, height: 1920), progress: 1)
        XCTAssertLessThanOrEqual(wide.width, 1080)
        XCTAssertEqual(wide.midX, 540, accuracy: 0.5)
        XCTAssertEqual(wide.width / wide.height, 4, accuracy: 0.01)
        let start = Brand.placement(of: CGSize(width: 400, height: 100), in: CGSize(width: 1080, height: 1920), progress: 0)
        XCTAssertLessThan(start.width, wide.width, "It grows a little while it shows")
    }

    /// End to end: a picture opens the movie, a video closes it, the song
    /// plays from the first frame to the last, and the length is as planned.
    func testTheMovieOpensAndClosesOnTheBrand() async throws {
        var project = LocalProject(name: "brand", source: "source.mov")
        let projectFolder = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: projectFolder)}
        let source = LocalStore.file(project.source, project: project.id)
        try await UITestFixture.makeRide(source, seconds: 8, width: 160, height: 120)
        project.duration = try await AVURLAsset(url: source).load(.duration).seconds
        project.analyzed = true
        try writeWave(projectFolder.appendingPathComponent("song.wav"), seconds: 40)
        project.music = [LocalMusic(file: "song.wav", name: "song", duration: 40)]

        try Brand.setImage(logo(), for: .intro)
        let closing = folder.appendingPathComponent("closing.mov")
        try await UITestFixture.makeRide(closing, seconds: 2, width: 120, height: 160)
        try await Brand.setVideo(closing, for: .outro)

        let engine = LocalEngine()
        var edit = Edit(clips: [Clip(start: 0, end: 3.5), Clip(start: 4, end: 7.5)])
        edit.settings["transition"] = .text(SmartTransitions.name)
        edit.settings["transitionDuration"] = .text("0.5")
        edit.settings["whoosh"] = .flag(true)
        let plannedLength = await engine.plannedLength(project, edit: edit)
        let planned = try XCTUnwrap(plannedLength)
        XCTAssertEqual(planned, 2.5 + 3.5 + 3.5 + 2 - 3 * 0.5, accuracy: 0.1)

        let preview = try await engine.previewEdit(project, edit: edit)
        let span = try await preview.composition.load(.duration).seconds
        XCTAssertEqual(span, planned, accuracy: 0.1)
        // The song is one stretch from the first frame to the last.
        let songs = preview.composition.tracks(withMediaType: .audio).filter {track in
            track.segments.contains {!$0.isEmpty && $0.timeMapping.target.start.seconds < 0.01}
        }
        let song = try XCTUnwrap(songs.first)
        XCTAssertEqual(song.timeRange.end.seconds, span, accuracy: 0.1)

        let output = projectFolder.appendingPathComponent("brand.mp4")
        let length = try await engine.export(project, edit: edit, output: output) {_, _ in}
        XCTAssertEqual(length, planned, accuracy: 0.001)
        let actual = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(actual, planned, accuracy: 0.1)
        let opening = try await frame(output, at: 1.5)
        XCTAssertGreaterThan(lime(opening), 20, "The logo opens the movie")
        let footage = try await frame(output, at: 4.5)
        XCTAssertLessThan(lime(footage), 3, "The clips have no logo")
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty, "The movie has its music")
    }

    private func writeWave(_ url: URL, seconds: Double) throws {
        let rate = 8000, count = Int(seconds * Double(rate))
        var data = Data()
        func text(_ s: String) {data.append(contentsOf: s.utf8)}
        func word(_ n: UInt16) {data.append(UInt8(n & 255)); data.append(UInt8(n >> 8))}
        func long(_ n: UInt32) {word(UInt16(n & 65535)); word(UInt16(n >> 16))}
        text("RIFF"); long(UInt32(36 + count * 2)); text("WAVEfmt "); long(16); word(1); word(1); long(UInt32(rate)); long(UInt32(rate * 2)); word(2); word(16)
        text("data"); long(UInt32(count * 2))
        for index in 0..<count {
            word(UInt16(bitPattern: Int16(sin(Double(index) / Double(rate) * 2 * .pi * 220) * 2500)))
        }
        try data.write(to: url)
    }
    private func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
    /// How many of the picture, shrunk to 32×32, are the logo's lime green.
    private func lime(_ image: CGImage) -> Int {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes {buffer in
            let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter {bytes[$0] > 140 && bytes[$0 + 1] > 180 && bytes[$0 + 2] < 130}.count
    }
}
