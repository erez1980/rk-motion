import AVFoundation
import UIKit

/// The rider's own opening and closing: a logo picture or a short video
/// chosen once from Photos, kept on the iPhone and added to every movie
/// until it is removed. Each plays as a shot of its own, so the edit's
/// transitions lead into and out of it and the music runs on under it.
enum Brand {
    enum Slot: String, CaseIterable, Identifiable {
        case intro, outro
        var id: String {rawValue}
        /// The edit's switch for this slot; on unless turned off.
        var setting: String {self == .intro ? "brandIntro" : "brandOutro"}
    }
    enum Kind: String, Codable {case image, video}
    struct Asset: Codable, Equatable {
        let kind: Kind
        /// The file's name inside `folder`; a new choice gets a new name.
        let file: String
        /// How long it plays in the movie.
        let seconds: Double
    }
    /// How long a picture stays, the longest stretch of a video that is
    /// used, and the shortest video accepted.
    static let imageSeconds = 2.5, longest = 8.0, shortest = 0.5

    /// Where the chosen files live; tests point it elsewhere.
    nonisolated(unsafe) static var folder = LocalStore.directory("brand")
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    private static func key(_ slot: Slot) -> String {"brand." + slot.rawValue}

    static func url(_ asset: Asset) -> URL {folder.appendingPathComponent(asset.file)}
    /// The kept choice for a slot, nil when there is none or its file is gone.
    static func asset(_ slot: Slot) -> Asset? {
        guard let data = defaults.data(forKey: key(slot)), let asset = try? JSONDecoder().decode(Asset.self, from: data),
              asset.seconds.isFinite, asset.seconds >= shortest, FileManager.default.fileExists(atPath: url(asset).path) else {return nil}
        return asset
    }
    /// What the edit plays in a slot: the kept choice, unless the edit turned it off.
    static func shot(_ slot: Slot, settings: [String: Setting]) -> Asset? {
        settings[slot.setting]?.bool == false ? nil : asset(slot)
    }
    /// The transition into the opening or out to the closing: the edit's
    /// own, and for smart transitions a dip through black into the movie and
    /// a rush towards the viewer out of it.
    static func style(_ slot: Slot, transition: String) -> String {
        guard transition == SmartTransitions.name else {return transition}
        return slot == .intro ? "fade" : "zoom"
    }

    private static func keep(_ asset: Asset, for slot: Slot) throws {
        let previous = Self.asset(slot)
        defaults.set(try JSONEncoder().encode(asset), forKey: key(slot))
        if let previous, previous.file != asset.file {try? FileManager.default.removeItem(at: url(previous))}
    }
    /// Keeps a picture as the slot's choice, upright and at most 2048 pixels on its long side.
    @discardableResult static func setImage(_ data: Data, for slot: Slot) throws -> Asset {
        guard let picked = UIImage(data: data), picked.size.width >= 1, picked.size.height >= 1 else {
            throw AppError(message: "לא ניתן לקרוא את התמונה שנבחרה.")
        }
        let scale = min(1, 2048 / max(picked.size.width * picked.scale, picked.size.height * picked.scale))
        let size = CGSize(width: max(1, (picked.size.width * picked.scale * scale).rounded()), height: max(1, (picked.size.height * picked.scale * scale).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        // Drawn again so the stored picture is upright whatever its orientation flag said.
        let upright = UIGraphicsImageRenderer(size: size, format: format).image {_ in picked.draw(in: CGRect(origin: .zero, size: size))}
        guard let png = upright.pngData() else {throw AppError(message: "לא ניתן לקרוא את התמונה שנבחרה.")}
        let asset = Asset(kind: .image, file: "\(slot.rawValue)-\(UUID().uuidString).png", seconds: imageSeconds)
        try png.write(to: url(asset), options: .atomic)
        do {try keep(asset, for: slot)} catch {try? FileManager.default.removeItem(at: url(asset)); throw error}
        return asset
    }
    /// Keeps a video as the slot's choice: its first `longest` seconds play.
    /// The file at `source` is moved, not copied.
    @discardableResult static func setVideo(_ source: URL, for slot: Slot) async throws -> Asset {
        let movie = AVURLAsset(url: source)
        let duration = try await movie.load(.duration).seconds
        guard try await movie.loadTracks(withMediaType: .video).first != nil, duration.isFinite, duration >= shortest else {
            throw AppError(message: "לא ניתן לקרוא את הסרטון שנבחר.")
        }
        let ending = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let asset = Asset(kind: .video, file: "\(slot.rawValue)-\(UUID().uuidString).\(ending)", seconds: min(longest, duration))
        try FileManager.default.moveItem(at: source, to: url(asset))
        do {try keep(asset, for: slot)} catch {try? FileManager.default.removeItem(at: url(asset)); throw error}
        return asset
    }
    static func remove(_ slot: Slot) {
        if let asset = asset(slot) {try? FileManager.default.removeItem(at: url(asset))}
        defaults.removeObject(forKey: key(slot))
    }

    /// The picture fitted inside a frame `size` big on black, growing a
    /// little over the shot so it does not stand still; `progress` 0 … 1.
    static func placement(of image: CGSize, in size: CGSize, progress: Double) -> CGRect {
        let t = max(0, min(1, progress)), eased = t * t * (3 - 2 * t)
        let fit = min(size.width * 0.8 / image.width, size.height * 0.8 / image.height) * CGFloat(0.94 + 0.06 * eased)
        let w = image.width * fit, h = image.height * fit
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
    /// The movie the edit lays in for an asset: the video itself, or the
    /// picture drawn into a movie the size of the frame, made once.
    static func movie(_ asset: Asset, size: CGSize) async throws -> URL {
        guard asset.kind == .image else {return url(asset)}
        let width = Int(size.width), height = Int(size.height)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let target = caches.appendingPathComponent("rk-brand-\((asset.file as NSString).deletingPathExtension)-\(width)x\(height).mov")
        if FileManager.default.fileExists(atPath: target.path) {return target}
        guard let picture = UIImage(contentsOfFile: url(asset).path)?.cgImage else {throw AppError(message: "לא ניתן לקרוא את התמונה שנבחרה.")}
        let partial = caches.appendingPathComponent("rk-brand-\(UUID().uuidString).mov")
        defer {try? FileManager.default.removeItem(at: partial)}
        let failed = AppError(message: NSLocalizedString("הכנת הפתיח או הסיומת נכשלה.", comment: "Making the brand opening or closing movie failed"))
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else {throw writer.error ?? failed}
        writer.startSession(atSourceTime: .zero)
        let frames = Int((asset.seconds * 30).rounded())
        let image = CGSize(width: picture.width, height: picture.height)
        for frame in 0..<frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {throw writer.error ?? failed}
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adapter.pixelBufferPool else {throw failed}
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer else {throw failed}
            CVPixelBufferLockBaseAddress(pixels, [])
            let drawn: Bool = {
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {return false}
                context.setFillColor(UIColor.black.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .high
                context.draw(picture, in: placement(of: image, in: size, progress: Double(frame) / Double(max(1, frames - 1))))
                return true
            }()
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard drawn, adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                writer.cancelWriting(); throw writer.error ?? failed
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else {throw writer.error ?? failed}
        if !FileManager.default.fileExists(atPath: target.path) {try? FileManager.default.moveItem(at: partial, to: target)}
        guard FileManager.default.fileExists(atPath: target.path) else {throw failed}
        return target
    }
    /// A small picture of the choice, for its row.
    static func thumbnail(_ asset: Asset, side: CGFloat) async -> CGImage? {
        switch asset.kind {
        case .image:
            guard let image = UIImage(contentsOfFile: url(asset).path) else {return nil}
            return image.preparingThumbnail(of: CGSize(width: side, height: side * image.size.height / max(1, image.size.width)))?.cgImage
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url(asset)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: side, height: side)
            return try? await generator.image(at: CMTime(seconds: min(asset.seconds / 2, 1), preferredTimescale: 600)).image
        }
    }
}
