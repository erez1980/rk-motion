import AVFoundation
import UIKit

/// The RK Motion end screen: the last shot rushes away into black, the
/// app icon springs up and "Made with" comes in above it. It is drawn on the device into a short movie, made once
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
    /// whose origin is the top left: black, then the app icon springs up
    /// fast, and "Made with" comes in above it.
    static func draw(_ context: CGContext, at time: Double, size: CGSize) {
        let w = size.width, h = size.height, s = min(w, h)
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let side = s * 0.4, center = CGPoint(x: w / 2, y: h / 2 + s * 0.04)
        let pop = (time - overlap - 0.05) / 0.4
        if pop > 0 {
            context.saveGState()
            context.setAlpha(CGFloat(clamp(pop * 4)))
            let scale = 0.2 + 0.8 * back(pop), turn = (1 - easeOut(pop)) * -0.25
            context.translateBy(x: center.x, y: center.y); context.rotate(by: turn); context.scaleBy(x: scale, y: scale)
            icon(context, side: side)
            context.restoreGState()
        }
        UIGraphicsPushContext(context)
        defer {UIGraphicsPopContext()}
        let rise = (time - overlap - 0.3) / 0.35
        if rise > 0 {
            let points = (s * 0.075).rounded(), eased = easeOut(rise)
            let font = RK.uiFont(points, 600).withSize(points)
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let height = ceil(font.lineHeight * 1.2)
            let top = center.y - side / 2 - s * 0.05 - height + s * 0.04 * CGFloat(1 - eased)
            ("Made with" as NSString).draw(with: CGRect(x: 0, y: top, width: w, height: height), options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .foregroundColor: UIColor.white.withAlphaComponent(CGFloat(clamp(rise * 1.5))), .paragraphStyle: style], context: nil)
        }
    }
    /// The app icon, `side` wide around the context's origin, drawn the way
    /// the icon file is: a dark tile lit green from two corners, the speed
    /// lines and the play triangle.
    private static func icon(_ context: CGContext, side: CGFloat) {
        let unit = side / 1024
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {CGPoint(x: (x - 512) * unit, y: (y - 512) * unit)}
        let tile = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: tile, cornerRadius: side * 0.215).cgPath); context.clip()
        context.setFillColor(background.cgColor); context.fill(tile)
        let space = CGColorSpaceCreateDeviceRGB()
        for (spot, color) in [(point(1000, 60), UIColor(red: 0x36 / 255, green: 0x44 / 255, blue: 0x1a / 255, alpha: 1)),
                              (point(60, 980), UIColor(red: 0x15 / 255, green: 0x2e / 255, blue: 0x1e / 255, alpha: 1))] {
            if let glow = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0.2, 1]) {
                context.drawRadialGradient(glow, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: side * 0.6, options: [])
            }
        }
        context.setStrokeColor(lines.cgColor); context.setLineWidth(52 * unit); context.setLineCap(.round)
        for (from, to, y) in [(176.0, 334.0, 392.0), (136.0, 344.0, 512.0), (176.0, 334.0, 632.0)] {
            context.strokeLineSegments(between: [point(CGFloat(from), CGFloat(y)), point(CGFloat(to), CGFloat(y))])
        }
        context.setFillColor(accent.cgColor)
        context.move(to: point(438, 268)); context.addLine(to: point(880, 512)); context.addLine(to: point(438, 756)); context.closePath()
        context.fillPath()
        context.restoreGState()
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
        let url = caches.appendingPathComponent("rk-outro-2-\(width)x\(height).mov")
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
