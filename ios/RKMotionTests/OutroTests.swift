import XCTest
import AVFoundation
@testable import RKMotion

/// Every movie opens from black and ends on the RK Motion end screen.
final class OutroTests: XCTestCase {
    func testTheEndScreenNeedsALongEnoughMovie() {
        let long = LocalEngine.timeline(clips: [Clip(start: 0, end: 4), Clip(start: 5, end: 8)], speed: 1, transition: 0)
        XCTAssertTrue(Outro.applies([:], segments: long))
        XCTAssertEqual(try XCTUnwrap(Outro.length([:], segments: long)), 7 + Outro.added, accuracy: 0.0001)
        XCTAssertFalse(Outro.applies(["outro": .flag(false)], segments: long), "The rider can turn it off")
        XCTAssertEqual(try XCTUnwrap(Outro.length(["outro": .flag(false)], segments: long)), 7, accuracy: 0.0001)
        let short = LocalEngine.timeline(clips: [Clip(start: 0, end: 3)], speed: 1, transition: 0)
        XCTAssertFalse(Outro.applies([:], segments: short), "A few seconds are too short for an end screen")
        XCTAssertNil(Outro.length([:], segments: []))
    }
    func testTheMusicRisesFromSilence() {
        let points = Ducking.envelope([], volume: 0.8, length: 20, fadeIn: 0.6)
        XCTAssertEqual(points.first?.volume, 0)
        XCTAssertEqual(try XCTUnwrap(points.first {abs($0.time - 0.6) < 0.0001}).volume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(Ducking.envelope([], volume: 0.8, length: 20).first?.volume, 0.8, "Without a fade in the song starts at its level")
        // A movie shorter than the closing fade still rises from silence, then fades out.
        let short = Ducking.envelope([], volume: 0.8, length: 2, fadeIn: 0.6)
        XCTAssertEqual(short.first?.volume, 0)
        XCTAssertEqual(try XCTUnwrap(short.first {abs($0.time - 0.5) < 0.0001}).volume, 0.8 * 0.75, accuracy: 0.0001)
        XCTAssertEqual(short.last?.volume, 0)
    }
    func testTheEndScreenDrawsTheLogo() throws {
        let size = CGSize(width: 270, height: 480)
        XCTAssertEqual(lime(try XCTUnwrap(Outro.image(at: 0.1, size: size))), 0, "Only the dark screen while the last shot leaves")
        XCTAssertGreaterThan(lime(try XCTUnwrap(Outro.image(at: Outro.seconds - 0.05, size: size))), 2, "The app icon stands at the end")
    }
    /// End to end: the movie opens dark, the planned length counts the end
    /// screen, and the last frames show the green logo the footage never has.
    func testTheMovieOpensFromBlackAndEndsOnTheLogo() async throws {
        var project = LocalProject(name: "outro", source: "source.mov")
        let folder = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let source = LocalStore.file(project.source, project: project.id)
        try await UITestFixture.makeRide(source, seconds: 8, width: 160, height: 120)
        project.duration = try await AVURLAsset(url: source).load(.duration).seconds
        project.analyzed = true
        let engine = LocalEngine()
        var edit = Edit(clips: [Clip(start: 0, end: 3.5), Clip(start: 4, end: 7.5)])
        edit.settings["useMusic"] = .flag(false); edit.settings["transition"] = .text("cut")
        let plannedLength = await engine.plannedLength(project, edit: edit)
        let planned = try XCTUnwrap(plannedLength)
        XCTAssertEqual(planned, 7 + Outro.added, accuracy: 0.01)
        let output = folder.appendingPathComponent("outro.mp4")
        let length = try await engine.export(project, edit: edit, output: output) {_, _ in}
        XCTAssertEqual(length, planned, accuracy: 0.001)
        let actual = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(actual, planned, accuracy: 0.1)
        let opening = try await frame(output, at: 0.02), later = try await frame(output, at: 1.5)
        XCTAssertLessThan(brightness(opening), brightness(later) * 0.5, "The movie should open from black")
        let footage = try await frame(output, at: 5), ending = try await frame(output, at: actual - 0.1)
        XCTAssertEqual(lime(footage), 0, "The footage has no logo green")
        XCTAssertGreaterThan(lime(ending), 2, "The movie should end on the app icon")
        // Turned off, the movie is only its shots again.
        edit.settings["outro"] = .flag(false)
        let plainLength = await engine.plannedLength(project, edit: edit)
        let plain = try XCTUnwrap(plainLength)
        XCTAssertEqual(plain, 7, accuracy: 0.01)
        let preview = try await engine.preview(project, edit: edit)
        let previewLength = try await preview.asset.load(.duration).seconds
        XCTAssertEqual(previewLength, plain, accuracy: 0.1)
    }

    private func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
    /// The picture shrunk to 32×32 RGBA.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        bytes.withUnsafeMutableBytes {buffer in
            let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return bytes
    }
    private func brightness(_ image: CGImage) -> Double {
        let values = pixels(image)
        return stride(from: 0, to: values.count, by: 4).reduce(0.0) {$0 + Double(values[$1]) + Double(values[$1 + 1]) + Double(values[$1 + 2])} / Double(values.count / 4 * 3)
    }
    /// How many of the shrunk picture's pixels are the logo's lime green.
    private func lime(_ image: CGImage) -> Int {
        let values = pixels(image)
        return stride(from: 0, to: values.count, by: 4).filter {values[$0] > 140 && values[$0 + 1] > 180 && values[$0 + 2] < 130}.count
    }
}
