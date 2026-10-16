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
        let analysis = try await engine.analyze(source, whole: false) {fraction, text in print("NATIVE ANALYSIS: \(fraction) \(text)")}
        let duration = analysis.duration, scores = analysis.scores
        // Whatever the simulator's classifiers manage, the scan reads the video as something.
        XCTAssertNotNil(analysis.reading)
        XCTAssertEqual(analysis.signals?.motion.count, 3)
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
        // The song starts a second in, through its own start point.
        edit.setMusicStart(1, for: project.music[0].id)
        let output = folder.appendingPathComponent("result.mp4")
        let expected: Double
        do {
            expected = try await engine.export(project, edit: edit, output: output) {fraction, text in print("NATIVE EXPORT: \(fraction) \(text)")}
        } catch {
            // A bare CancellationError says nothing about who cancelled. Whether
            // this test's own task is cancelled separates "something is
            // cancelling us" from "the export session cancelled itself".
            XCTFail("export threw \(type(of: error)): \(error) · test task cancelled: \(Task.isCancelled) · output written: \(FileManager.default.fileExists(atPath: output.path))")
            throw error
        }
        let preview = try await engine.preview(project, edit: edit)
        let previewDuration = try await preview.asset.load(.duration).seconds
        XCTAssertEqual(previewDuration, expected, accuracy: 0.1)
        // Smart transitions pick each seam's own from the saved scan and keep the movie's length.
        try LocalStore.writeSignals(try XCTUnwrap(analysis.signals), project: project.id)
        var smart = edit
        smart.settings["transition"] = .text(SmartTransitions.name)
        let smartPreview = try await engine.preview(project, edit: smart)
        let smartDuration = try await smartPreview.asset.load(.duration).seconds
        XCTAssertEqual(smartDuration, expected, accuracy: 0.1)
        // Slow motion on the strongest second makes the movie longer, and the
        // planned length, the preview and the export agree on it.
        var scored = project
        scored.scores = scores
        var slow = Edit(clips: [Clip(start: 0.1, end: 2.9)])
        slow.settings["slowPeak"] = .flag(true)
        slow.settings["aspect"] = .text("9:16")
        let slowLength = try XCTUnwrap(await engine.plannedLength(scored, edit: slow))
        XCTAssertEqual(slowLength, 2.8 + Clip.slowSpan, accuracy: 0.05)
        let slowPreview = try await engine.preview(scored, edit: slow)
        let slowDuration = try await slowPreview.asset.load(.duration).seconds
        XCTAssertEqual(slowDuration, slowLength, accuracy: 0.1)
        // A read video exports with its mood's colour, in the title's second pass.
        scored.reading = analysis.reading
        let graded = folder.appendingPathComponent("graded.mp4")
        let gradedLength = try await engine.export(scored, edit: slow, output: graded) {_, _ in}
        let gradedDuration = try await AVURLAsset(url: graded).load(.duration).seconds
        XCTAssertEqual(gradedDuration, gradedLength, accuracy: 0.1)
        XCTAssertEqual(preview.videoComposition?.renderSize, CGSize(width: 134, height: 240))
        XCTAssertNotNil(preview.audioMix)
        // The music track takes the song from the chosen second, not from its beginning.
        let previewAudio = try await preview.asset.loadTracks(withMediaType: .audio)
        let songSegments = previewAudio.compactMap {$0 as? AVCompositionTrack}.flatMap {$0.segments}
            .filter {!$0.isEmpty && $0.sourceURL?.lastPathComponent == "music.wav"}
        let firstSong = try XCTUnwrap(songSegments.min {$0.timeMapping.target.start < $1.timeMapping.target.start})
        XCTAssertEqual(firstSong.timeMapping.target.start.seconds, 0, accuracy: 0.01)
        XCTAssertEqual(firstSong.timeMapping.source.start.seconds, 1, accuracy: 0.01)
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
        // Both tolerances default to positive infinity, which lets the
        // generator hand back any frame it likes - usually an early keyframe.
        // The fade can only be measured on the frame that was asked for.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let wanted = max(0, actual - 0.05)
        let (lastImage, sampled) = try await generator.image(at: CMTime(seconds: wanted, preferredTimescale: 600))
        XCTAssertEqual(sampled.seconds, wanted, accuracy: 0.05, "The fade check has to look at the closing frames")
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
        // The opening title is drawn into the frame: the same edit with and
        // without it differs low on the picture while the title shows, and
        // not once it has faded.
        var plain = Edit(clips: [Clip(start: 0, end: 2.5)])
        plain.settings["useMusic"] = .flag(false)
        var titled = plain
        titled.settings["titleText"] = .text("  רכיבת בוקר  ")
        titled.settings["subtitleText"] = .text("Ben Shemen · 14.10")
        XCTAssertEqual(titled.openingTitle.title, "רכיבת בוקר")
        let plainOutput = folder.appendingPathComponent("plain.mp4"), titledOutput = folder.appendingPathComponent("titled.mp4")
        let titledLength = try await engine.export(project, edit: titled, output: titledOutput) {_, _ in}
        _ = try await engine.export(project, edit: plain, output: plainOutput) {_, _ in}
        let shown = LocalEngine.titleTimes(length: titledLength)
        let during = (shown.start + shown.end) / 2
        let withTitle = try await lowerGray(titledOutput, at: during), without = try await lowerGray(plainOutput, at: during)
        XCTAssertGreaterThan(zip(withTitle, without).map {abs(Double($0) - Double($1))}.reduce(0, +) / Double(withTitle.count), 12, "The title should show over the opening")
        let after = min(titledLength - 0.1, shown.end + 0.2)
        let laterWith = try await lowerGray(titledOutput, at: after), laterWithout = try await lowerGray(plainOutput, at: after)
        XCTAssertLessThan(zip(laterWith, laterWithout).map {abs(Double($0) - Double($1))}.reduce(0, +) / Double(laterWith.count), 6, "The title should be gone after the opening")
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
    func testWaveformOfASong() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let wave = folder.appendingPathComponent("song.wav")
        try makeAudio(wave)
        let levels = try await LocalEngine.waveform(wave, bins: 30)
        XCTAssertEqual(levels.count, 30)
        XCTAssertEqual(levels.max() ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(levels.allSatisfy {$0.isFinite && (0...1).contains($0)})
        // The fixture is quiet, loud, then medium; the drawing must say so.
        XCTAssertGreaterThan(levels[15], levels[5] * 3)
        XCTAssertGreaterThan(levels[15], levels[25] * 2)
    }
    /// The lower 40% of one frame, shrunk to a 16×8 grid of gray levels.
    private func lowerGray(_ url: URL, at seconds: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let lower = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: Int(Double(image.height) * 0.6), width: image.width, height: Int(Double(image.height) * 0.4))))
        var gray = [UInt8](repeating: 0, count: 128)
        gray.withUnsafeMutableBytes {bytes in
            let context = CGContext(data: bytes.baseAddress, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(lower, in: CGRect(x: 0, y: 0, width: 16, height: 8))
        }
        return gray
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
