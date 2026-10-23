import AVFoundation
import UIKit

/// The RK Motion end screen: the last shot rushes away into a dark screen
/// where the logo springs in, its speed lines slide up to it and the name
/// rises under it. It is drawn on the device into a short movie, made once
/// per frame size, and laid after the edit so the preview shows it too.
enum Outro {
    /// The end screen's own length, and how much of it plays under the
    /// last shot while that shot leaves.
    static let seconds = 2.6, overlap = 0.5
    /// A movie shorter than this ends without the end screen.
    static let shortest = 5.0
    /// Every movie opens from black over this long.
    static let fadeIn = 0.6
    /// How much longer the movie gets.
    static var added: Double {seconds - overlap}
    static let accent = UIColor(red: 0xc8 / 255, green: 0xf5 / 255, blue: 0x42 / 255, alpha: 1)
    static let lines = UIColor(red: 0x6f / 255, green: 0x8c / 255, blue: 0x2f / 255, alpha: 1)
    static let background = UIColor(red: 0x0b / 255, green: 0x0f / 255, blue: 0x0b / 255, alpha: 1)

    /// Whether the edit ends on the end screen: asked for, long enough, and
    /// with a last shot long enough to leave under it.
    static func applies(_ settings: [String: Setting], segments: [LocalEngine.Segment]) -> Bool {
        guard settings["outro"]?.bool != false, let last = segments.last, last.end >= shortest else {return false}
        return last.duration - last.incoming > overlap + 0.1
    }
    /// The movie's length with the end screen, when it has one.
    static func length(_ settings: [String: Setting], segments: [LocalEngine.Segment]) -> Double? {
        guard let end = segments.last?.end else {return nil}
        return end + (applies(settings, segments: segments) ? added : 0)
    }

    private static func clamp(_ value: Double) -> Double {min(1, max(0, value))}
    private static func easeOut(_ p: Double) -> Double {1 - pow(1 - clamp(p), 3)}
    /// Overshoots a little and settles, like a spring.
    private static func back(_ p: Double) -> Double {
        let p = clamp(p), c = 1.9
        return 1 + (c + 1) * pow(p - 1, 3) + c * pow(p - 1, 2)
    }

    /// Draws the end screen as it looks `time` seconds in, into a context
    /// whose origin is the top left.
    static func draw(_ context: CGContext, at time: Double, size: CGSize) {
        let w = size.width, h = size.height, s = min(w, h)
        context.setFillColor(background.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let center = CGPoint(x: w / 2, y: h / 2 - s * 0.08)
        // A soft green glow grows behind the logo.
        let glow = easeOut((time - overlap) / 0.9)
        if glow > 0, let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [accent.withAlphaComponent(0.22 * glow).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.75, options: [])
        }
        // The logo is drawn in the app icon's own 1024 units around its middle.
        let unit = s * 0.42 / 770
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {CGPoint(x: center.x + (x - 495) * unit, y: center.y + (y - 512) * unit)}
        // A ring rings out as the logo lands.
        let ring = (time - overlap - 0.4) / 0.6
        if ring > 0 && ring < 1 {
            let radius = s * (0.12 + 0.28 * easeOut(ring))
            context.setStrokeColor(accent.withAlphaComponent(0.55 * (1 - ring)).cgColor)
            context.setLineWidth(max(1, s * 0.008))
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        // The speed lines slide in from the left, one after another.
        for (index, (from, to, y)) in [(150.0, 360.0, 392.0), (110.0, 370.0, 512.0), (150.0, 360.0, 632.0)].enumerated() {
            let p = (time - overlap - 0.2 - Double(index) * 0.07) / 0.35
            guard p > 0 else {continue}
            let shift = (1 - easeOut(p)) * -Double(s) * 0.45
            let a = point(CGFloat(from) + 26, CGFloat(y)), b = point(CGFloat(to) - 26, CGFloat(y))
            context.setStrokeColor(lines.withAlphaComponent(CGFloat(clamp(p * 2))).cgColor)
            context.setLineWidth(52 * unit); context.setLineCap(.round)
            context.strokeLineSegments(between: [CGPoint(x: a.x + shift, y: a.y), CGPoint(x: b.x + shift, y: b.y)])
        }
        // The play triangle springs up from nothing with a small turn.
        let pop = (time - overlap) / 0.55
        if pop > 0 {
            let scale = back(pop), turn = (1 - easeOut(pop)) * -0.35
            let middle = point(585, 512)
            context.saveGState()
            context.translateBy(x: middle.x, y: middle.y); context.rotate(by: turn); context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -middle.x, y: -middle.y)
            context.setFillColor(accent.withAlphaComponent(CGFloat(clamp(pop * 3))).cgColor)
            context.move(to: point(438, 268)); context.addLine(to: point(880, 512)); context.addLine(to: point(438, 756)); context.closePath()
            context.fillPath()
            context.restoreGState()
        }
        // "Made with RK Motion" rises under the logo, its letters closing up as it comes.
        UIGraphicsPushContext(context)
        defer {UIGraphicsPopContext()}
        func text(_ string: String, at y: CGFloat, size points: CGFloat, weight: CGFloat, color: UIColor, start: Double, spread: CGFloat) {
            let p = (time - start) / 0.45
            guard p > 0 else {return}
            let eased = easeOut(p)
            let font = RK.uiFont(points, weight).withSize(points)
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(CGFloat(clamp(p * 1.5))),
                .paragraphStyle: style, .kern: points * spread * CGFloat(1 - eased)]
            let height = ceil(font.lineHeight * 1.2), rise = s * 0.05 * CGFloat(1 - eased)
            (string as NSString).draw(with: CGRect(x: 0, y: y + rise, width: w, height: height), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
        let below = point(0, 756).y + s * 0.08
        text("MADE WITH", at: below, size: max(6, (s * 0.034).rounded()), weight: 500, color: accent, start: overlap + 0.5, spread: 0.6)
        text("RK Motion", at: below + s * 0.055, size: (s * 0.1).rounded(), weight: 700, color: .white, start: overlap + 0.65, spread: 0.25)
    }

    /// One frame of the end screen as a picture.
    static func image(at time: Double, size: CGSize) -> CGImage? {
        guard size.width >= 2, size.height >= 2 else {return nil}
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image {draw($0.cgContext, at: time, size: size)}.cgImage
    }

    /// The end screen as a movie the size of the frame, written once and kept in the caches.
    static func file(size: CGSize) async throws -> URL {
        let width = Int(size.width), height = Int(size.height)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("rk-outro-1-\(width)x\(height).mov")
        if FileManager.default.fileExists(atPath: url.path) {return url}
        let partial = caches.appendingPathComponent("rk-outro-\(UUID().uuidString).mov")
        defer {try? FileManager.default.removeItem(at: partial)}
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? AppError(message: "יצירת מסך הסיום נכשלה.")}
        writer.startSession(atSourceTime: .zero)
        let frames = Int((seconds * 30).rounded())
        for frame in 0..<frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? AppError(message: "יצירת מסך הסיום נכשלה.")}
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adapter.pixelBufferPool else {throw AppError(message: "יצירת מסך הסיום נכשלה.")}
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer else {throw AppError(message: "יצירת מסך הסיום נכשלה.")}
            CVPixelBufferLockBaseAddress(pixels, [])
            let drawn: Bool = {
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {return false}
                // Core Graphics counts from the bottom; the drawing counts from the top.
                context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
                draw(context, at: Double(frame) / 30, size: size)
                return true
            }()
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard drawn, adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                writer.cancelWriting(); throw writer.error ?? AppError(message: "יצירת מסך הסיום נכשלה.")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? AppError(message: "יצירת מסך הסיום נכשלה.")}
        // Another edit may have written the same screen meanwhile; either copy will do.
        if !FileManager.default.fileExists(atPath: url.path) {try? FileManager.default.moveItem(at: partial, to: url)}
        guard FileManager.default.fileExists(atPath: url.path) else {throw AppError(message: "יצירת מסך הסיום נכשלה.")}
        return url
    }
}
