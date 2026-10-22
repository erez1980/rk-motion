import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Turns a photo into a few seconds of video that moves: a slow push in
/// towards what draws the eye, found by Vision on the device, so a photo
/// plays among the videos of a project like a clip of its own.
enum PhotoMotion {
    static let seconds = 4.0
    static let zoom = 1.18
    private static let fps: Int32 = 30

    /// Whether a file is a photo rather than a video.
    static func isPhoto(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
    /// The frame size of the video made from a photo `size` big: upright
    /// photos become 1080×1920, wide ones 1920×1080.
    static func frame(for size: CGSize) -> CGSize {
        size.height > size.width ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
    }
    /// The part of the photo shown at the start and at the end: the widest
    /// frame-shaped part around the focus, then a closer one on it.
    /// `focus` is in the photo's own coordinates, origin bottom left.
    static func path(image: CGSize, frame: CGSize, focus: CGPoint?) -> (from: CGRect, to: CGRect) {
        let aspect = frame.width / frame.height
        let width = min(image.width, image.height * aspect), height = width / aspect
        let centre = focus ?? CGPoint(x: image.width / 2, y: image.height / 2)
        func placed(_ w: CGFloat, _ h: CGFloat) -> CGRect {
            let x = min(max(0, centre.x - w / 2), image.width - w), y = min(max(0, centre.y - h / 2), image.height - h)
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return (placed(width, height), placed(width / zoom, height / zoom))
    }
    /// The crop at `progress` 0 … 1 of the way, eased in and out.
    static func crop(_ path: (from: CGRect, to: CGRect), at progress: Double) -> CGRect {
        let t = CGFloat(max(0, min(1, progress))), eased = t * t * (3 - 2 * t)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {a + (b - a) * eased}
        return CGRect(x: mix(path.from.minX, path.to.minX), y: mix(path.from.minY, path.to.minY),
                      width: mix(path.from.width, path.to.width), height: mix(path.from.height, path.to.height))
    }
    /// Where people look in the photo, in its own coordinates: the middle of
    /// the salient objects Vision finds; nil when it finds none.
    static func focus(of image: CIImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? VNImageRequestHandler(ciImage: image).perform([request])) != nil,
              let boxes = request.results?.first?.salientObjects?.map(\.boundingBox), !boxes.isEmpty else {return nil}
        let union = boxes.dropFirst().reduce(boxes[0]) {$0.union($1)}
        return CGPoint(x: image.extent.minX + union.midX * image.extent.width, y: image.extent.minY + union.midY * image.extent.height)
    }
    /// When the photo was taken, from its own EXIF.
    static func takenDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {return nil}
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return format.date(from: text)
    }
    /// Writes the photo in `data` as a moving video at `output` (QuickTime),
    /// dated when the photo was taken so it sorts among the videos.
    static func makeVideo(from data: Data, to output: URL) async throws {
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw AppError(message: "לא ניתן לקרוא את התמונה שנבחרה.")
        }
        let image = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
        let size = frame(for: image.extent.size)
        let small = image.transformed(by: CGAffineTransform(scaleX: 512 / max(image.extent.width, image.extent.height), y: 512 / max(image.extent.width, image.extent.height)))
        let look = focus(of: small).map {CGPoint(x: $0.x * image.extent.width / max(1, small.extent.width), y: $0.y * image.extent.height / max(1, small.extent.height))}
        let route = path(image: image.extent.size, frame: size, focus: look)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        if let date = takenDate(data) {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter().string(from: date) as NSString
            writer.metadata = [item]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        guard writer.canAdd(input) else {throw AppError(message: "לא ניתן להנפיש את התמונה.")}
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? AppError(message: "לא ניתן להנפיש את התמונה.")}
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let frames = Int(seconds * Double(fps))
        do {
            for index in 0..<frames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    // A writer that failed (a full disk) never becomes ready again.
                    if writer.status == .failed || writer.status == .cancelled {throw writer.error ?? AppError(message: "לא ניתן להנפיש את התמונה.")}
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else {throw writer.error ?? AppError(message: "לא ניתן להנפיש את התמונה.")}
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else {throw AppError(message: "לא ניתן להנפיש את התמונה.")}
                let part = crop(route, at: Double(index) / Double(max(1, frames - 1)))
                let scale = size.width / part.width
                let shown = image.cropped(to: part)
                    .transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
                context.render(shown, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpaceCreateDeviceRGB())
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
                    throw writer.error ?? AppError(message: "לא ניתן להנפיש את התמונה.")
                }
            }
        } catch {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: output)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? AppError(message: "לא ניתן להנפיש את התמונה.")}
    }
}
