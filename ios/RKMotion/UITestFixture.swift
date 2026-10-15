#if DEBUG
import AVFoundation
import CoreVideo

/// UI tests start the app with `-RKUITestFixture`: it makes a short ride of
/// its own and imports it the way a picked video is imported, so the tests
/// drive the real screens without touching Photos. Debug builds only.
enum UITestFixture {
    static var requested: Bool {ProcessInfo.processInfo.arguments.contains("-RKUITestFixture")}

    @MainActor static func load(into model: EditorModel) async {
        await model.discardTestRides()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rk-ui-fixture-\(UUID().uuidString).mov")
        do {try await makeRide(file)} catch {model.message = "fixture: \(error.localizedDescription)"; return}
        await model.importVideo(file)
        try? FileManager.default.removeItem(at: file)
    }

    /// Four seconds of a bright bar sweeping over a dark frame, so analysis
    /// sees motion and every frame differs.
    static func makeRide(_ url: URL, seconds: Int = 4, width: Int = 320, height: Int = 240) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? CocoaError(.fileWriteUnknown)}
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? CocoaError(.fileWriteUnknown)}
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adapter.pixelBufferPool else {throw CocoaError(.fileWriteUnknown)}
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer else {throw CocoaError(.fileWriteUnknown)}
            CVPixelBufferLockBaseAddress(pixels, [])
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let bar = (frame * 9) % width
            for y in 0..<height {for x in 0..<width {
                let lit = abs(x - bar) < 24
                let pos = y * row + x * 4
                bytes[pos] = lit ? 240 : 30; bytes[pos + 1] = lit ? 220 : UInt8(y % 64); bytes[pos + 2] = lit ? 60 : 20; bytes[pos + 3] = 255
            }}
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {throw writer.error ?? CocoaError(.fileWriteUnknown)}
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds * 30), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? CocoaError(.fileWriteUnknown)}
    }
}
#endif
