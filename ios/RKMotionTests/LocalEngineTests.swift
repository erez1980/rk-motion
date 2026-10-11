import XCTest
import AVFoundation
@testable import RKMotion

final class LocalEngineTests: XCTestCase {
    func testTimelineAndDownscaleCaps() {
        let clips = [Clip(start: 0, end: 4), Clip(start: 5, end: 7)]
        let timeline = LocalEngine.timeline(clips: clips, speed: 2, transition: 0.5)
        XCTAssertEqual(timeline[1].start, 1.5)
        XCTAssertEqual(timeline[1].end, 2.5)
        XCTAssertEqual(LocalEngine.frame(source: CGSize(width: 320, height: 240), cap: 1080, portrait: true), CGSize(width: 134, height: 240))
        let scores = [0.0, 0.8, 0.9, 0.0, 0.9, 0.8, 0.0]
        let ranges = LocalEngine.ranges(scores: scores, duration: 7)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 7)
        XCTAssertTrue(LocalEngine.normalized([0, 1, 2, 3, 100]).allSatisfy {$0.isFinite && (0...1).contains($0)})
    }
    func testPersistenceKeepsEditedSelectionAndSettings() throws {
        var project = LocalProject(name: "ride", source: "source.mov")
        try FileManager.default.createDirectory(at: LocalStore.folder(project.id), withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: LocalStore.folder(project.id))}
        try Data([0]).write(to: LocalStore.file(project.source, project: project.id))
        project.edit = Edit(clips: [Clip(start: 1, end: 3)])
        project.edit.clips[0].selected = false
        project.edit.settings["speed"] = .text("1.5")
        try LocalStore.save(project)
        let restored = try XCTUnwrap(LocalStore.load().first {$0.id == project.id})
        XCTAssertEqual(restored.edit, project.edit)
    }
    func testNativeAnalysisAndRotatedExportWithMusic() async throws {
        var project = LocalProject(name: "native fixture", source: "source.mov")
        let folder = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let video = folder.appendingPathComponent("silent.mov")
        try await makeVideo(video)
        print("NATIVE: fixture video created")
        let wave = folder.appendingPathComponent("music.wav")
        try makeAudio(wave)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: wave)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let v = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let a = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
        try v.insertTimeRange(range, of: videoTrack, at: .zero)
        v.preferredTransform = try await videoTrack.load(.preferredTransform)
        try a.insertTimeRange(range, of: audioTrack, at: .zero)
        let source = LocalStore.file(project.source, project: project.id)
        let merger = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        merger.outputURL = source; merger.outputFileType = .mov
        await withCheckedContinuation {c in merger.exportAsynchronously {c.resume()}}
        XCTAssertEqual(merger.status, .completed, merger.error?.localizedDescription ?? "")
        print("NATIVE: source merge completed")
        let engine = LocalEngine()
        let (duration, scores, _) = try await engine.analyze(source, whole: false) {fraction, text in print("NATIVE ANALYSIS: \(fraction) \(text)")}
        XCTAssertEqual(duration, 3, accuracy: 0.05)
        XCTAssertEqual(scores.count, 3)
        XCTAssertTrue(scores.allSatisfy {$0.isFinite})
        project.duration = duration; project.analyzed = true
        project.music = [LocalMusic(file: "music.wav", name: "music", duration: 3)]
        var edit = Edit(clips: [Clip(start: 0.2, end: 1.5), Clip(start: 1.7, end: 2.8)])
        edit.settings["speed"] = .text("1.25")
        edit.settings["transition"] = .text("dissolve")
        edit.settings["transitionDuration"] = .text("0.3")
        edit.settings["aspect"] = .text("9:16")
        let output = folder.appendingPathComponent("result.mp4")
        let expected = try await engine.export(project, edit: edit, output: output) {fraction, text in print("NATIVE EXPORT: \(fraction) \(text)")}
        let result = AVURLAsset(url: output)
        let actual = try await result.load(.duration).seconds
        XCTAssertEqual(actual, expected, accuracy: 0.1)
        let resultVideos = try await result.loadTracks(withMediaType: .video)
        let resultVideo = try XCTUnwrap(resultVideos.first)
        let size = try await resultVideo.load(.naturalSize)
        XCTAssertEqual(size.width, 134)
        XCTAssertEqual(size.height, 240)
        let resultAudios = try await result.loadTracks(withMediaType: .audio)
        XCTAssertFalse(resultAudios.isEmpty)
        let generator = AVAssetImageGenerator(asset: result)
        let (lastImage, _) = try await generator.image(at: CMTime(seconds: max(0, actual - 0.05), preferredTimescale: 600))
        var gray = [UInt8](repeating: 0, count: 64)
        gray.withUnsafeMutableBytes {bytes in
            let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(lastImage, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        XCTAssertLessThan(gray.reduce(0.0) {$0 + Double($1)} / 64, 40, "Closing fade should darken the final frames")
        var muted = Edit(clips: [Clip(start: 0, end: 1)])
        muted.settings["muteOriginal"] = .flag(true); muted.settings["useMusic"] = .flag(false)
        let silentOutput = folder.appendingPathComponent("muted.mp4")
        _ = try await engine.export(project, edit: muted, output: silentOutput) {_, _ in}
        let silentTracks = try await AVURLAsset(url: silentOutput).loadTracks(withMediaType: .audio)
        XCTAssertTrue(silentTracks.isEmpty)
        let canceled = Task {try await engine.analyze(source, whole: true) {_, _ in}}
        canceled.cancel()
        do {_ = try await canceled.value; XCTFail("Canceled analysis was accepted")} catch is CancellationError {} catch {XCTFail("Unexpected cancellation error: \(error)")}
        // Source is still retained for future edits; no intermediate source re-encode.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        edit.clips[0].end = 99
        do {
            _ = try await engine.export(project, edit: edit, output: folder.appendingPathComponent("invalid.mp4")) {_, _ in}
            XCTFail("Out-of-range edit accepted")
        } catch {XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("invalid.mp4").path))}
    }
    private func makeVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 426])
        input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 426, ty: 0)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 426])
        writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? AppError(message: "Fixture writer stopped")}
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer), kCVReturnSuccess)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<426 {for x in 0..<240 {
                let pos = y * row + x * 4
                bytes[pos] = UInt8((x + frame * 3) % 256); bytes[pos + 1] = UInt8((y + frame) % 256); bytes[pos + 2] = UInt8((frame * frame) % 256); bytes[pos + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 30))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
    private func makeAudio(_ url: URL) throws {
        var data = Data()
        func text(_ s: String) {data.append(contentsOf: s.utf8)}
        func word(_ n: UInt16) {data.append(UInt8(n & 255)); data.append(UInt8(n >> 8))}
        func long(_ n: UInt32) {word(UInt16(n & 65535)); word(UInt16(n >> 16))}
        let samples = 24000
        text("RIFF"); long(UInt32(36 + samples * 2)); text("WAVEfmt "); long(16); word(1); word(1); long(8000); long(16000); word(2); word(16)
        text("data"); long(UInt32(samples * 2))
        for i in 0..<samples {
            let amplitude = i < 8000 ? 3000.0 : i < 16000 ? 15000.0 : 6000.0
            word(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / 8000) * amplitude)))
        }
        try data.write(to: url)
    }
}
