import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

// Only native Apple frameworks: source files never leave the device.
actor LocalEngine {
    typealias Progress = @Sendable (Double, String) async -> Void
    private func time(_ seconds: Double) -> CMTime {CMTime(seconds: seconds, preferredTimescale: 60000)}
    static func normalized(_ values: [Double]) -> [Double] {
        let positive = values.filter {$0 > 0}.sorted()
        guard !positive.isEmpty else {return values.map {_ in 0}}
        let cap = positive[max(0, Int(ceil(Double(positive.count) * 0.95)) - 1)]
        let lower = positive[max(0, Int(floor(Double(positive.count) * 0.15)) - 1)]
        return values.map {max(0, min(1, ($0 - lower) / max(1e-9, cap - lower)))}
    }
    static func ranges(scores: [Double], duration: Double, threshold: Double = 0.55) -> [Clip] {
        let active = scores.indices.filter {scores[$0] >= threshold}
        var groups: [[Int]] = []
        for second in active {
            if let last = groups.last?.last, second <= last + 2 {groups[groups.count - 1].append(second)}
            else {groups.append([second])}
        }
        return groups.flatMap {group -> [Clip] in
            let first = group.first!, last = group.last!
            let start = max(0, Double(first) - 2), end = min(duration, Double(last) + 3)
            guard end - start >= min(5, duration) else {return []}
            let score = scores[first...last].reduce(0, +) / Double(last - first + 1)
            // Split long activity spans so the editor stays useful for long rides.
            return stride(from: start, to: end, by: 30).map {Clip(start: $0, end: min(end, $0 + 30), score: score)}
        }.sorted {($0.score ?? 0) > ($1.score ?? 0)}
    }
    func analyze(_ source: URL, whole: Bool, progress: Progress) async throws -> (Double, [Double], [Clip]) {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 24 * 3600,
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw AppError(message: "בחרו סרטון תקין באורך של עד 24 שעות.")
        }
        if whole {return (duration, [], [Clip(start: 0, end: duration)])}
        let count = max(1, Int(ceil(duration)))
        var motion = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        var previous: [UInt8]?
        let frameCount = Int(ceil(duration * 2))
        // Bounded batches avoid overlapping one-shot generator lifetimes and
        // keep decoded preview images out of memory after each small batch.
        for first in stride(from: 0, to: frameCount, by: 16) {
            try Task.checkCancellation()
            let last = min(frameCount, first + 16)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            generator.requestedTimeToleranceBefore = time(0.15)
            generator.requestedTimeToleranceAfter = time(0.15)
            let times = (first..<last).map {time(min(Double($0) / 2, max(0, duration - 0.05)))}
            var frames: [Int: [UInt8]] = [:]
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                switch result {
                case .success(let requested, let image, _):
                    frames[Int((requested.seconds * 2).rounded())] = try Self.gray(image)
                case .failure(_, let error): throw error
                }
            }
            for index in first..<last {
                guard let pixels = frames[index] else {throw AppError(message: "לא ניתן לקרוא פריים מהסרטון.")}
                if let previous {
                    let diff = zip(pixels, previous).reduce(0.0) {$0 + Double(abs(Int($1.0) - Int($1.1)))} / Double(255 * pixels.count)
                    let bucket = min(count - 1, index / 2); motion[bucket] += diff; counts[bucket] += 1
                }
                previous = pixels
            }
            await progress(0.8 * Double(last) / Double(frameCount), "מנתחת תנועה באייפון…")
        }
        for index in motion.indices where counts[index] > 0 {motion[index] /= Double(counts[index])}
        let audio = try await loudness(asset, duration: duration, progress: progress)
        let m = Self.normalized(motion), a = Self.normalized(audio)
        let scores = m.indices.map {0.65 * m[$0] + 0.35 * a[$0]}
        await progress(1, "הניתוח הושלם באייפון")
        return (duration, scores, Self.ranges(scores: scores, duration: duration))
    }
    private static func gray(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 160 * 90)
        try bytes.withUnsafeMutableBytes {buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw AppError(message: "לא ניתן לקרוא פריימים מהסרטון.")
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        }
        return bytes
    }
    private func loudness(_ asset: AVAsset, duration: Double, progress: Progress) async throws -> [Double] {
        let count = max(1, Int(ceil(duration)))
        var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {return sums}
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else {throw AppError(message: "לא ניתן לפענח את השמע בסרטון.")}
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? AppError(message: "קריאת השמע נכשלה.")}
        defer {reader.cancelReading()}
        var lastProgress = -1
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard start.isFinite else {throw AppError(message: "השמע מכיל חותמות זמן לא תקינות.")}
            try autoreleasepool {
                guard let block = CMSampleBufferGetDataBuffer(sample) else {return}
                let size = CMBlockBufferGetDataLength(block)
                var data = [UInt8](repeating: 0, count: size)
                let status = data.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)}
                guard status == kCMBlockBufferNoErr else {throw AppError(message: "קריאת דגימות השמע נכשלה.")}
                data.withUnsafeBytes {bytes in
                    for (index, value) in bytes.bindMemory(to: Float.self).enumerated() {
                        let bucket = min(count - 1, max(0, Int(start + Double(index) / 8000)))
                        if value.isFinite {sums[bucket] += Double(value * value); counts[bucket] += 1}
                    }
                }
            }
            let second = Int(start)
            if second >= lastProgress + 5 {lastProgress = second; await progress(0.8 + 0.2 * min(1, Double(second) / duration), "מנתחת שמע באייפון…")}
        }
        guard reader.status == .completed else {throw reader.error ?? AppError(message: "פענוח השמע הופסק.")}
        return sums.indices.map {counts[$0] > 0 ? sqrt(sums[$0] / Double(counts[$0])) : 0}
    }

    struct Segment {
        let start: Double
        let duration: Double
        let incoming: Double
        let outgoing: Double
        let track: Int
        var end: Double {start + duration}
    }
    static func timeline(clips: [Clip], speed: Double, transition: Double) -> [Segment] {
        var segments: [Segment] = [], cursor = 0.0
        for index in clips.indices {
            let length = clips[index].duration / speed
            let incoming = index == 0 ? 0 : min(transition, length / 2, clips[index - 1].duration / speed / 2)
            let outgoing = index == clips.count - 1 ? 0 : min(transition, length / 2, clips[index + 1].duration / speed / 2)
            let start = max(0, cursor - incoming)
            segments.append(Segment(start: start, duration: length, incoming: incoming, outgoing: outgoing, track: index % 2))
            cursor = start + length
        }
        return segments
    }
    static func frame(source: CGSize, cap: Double?, portrait: Bool) -> CGSize {
        var w = source.width, h = source.height
        if portrait {w = min(w, h * 9 / 16); h = min(h, source.width * 16 / 9)}
        let scale = min(1, (cap ?? h) / h)
        return CGSize(width: max(2, floor(w * scale / 2) * 2), height: max(2, floor(h * scale / 2) * 2))
    }
    func export(_ project: LocalProject, edit: Edit, output: URL, progress: @escaping Progress) async throws -> Double {
        let source = LocalStore.file(project.source, project: project.id)
        let asset = AVURLAsset(url: source)
        let total = try await asset.load(.duration).seconds
        let clips = edit.clips.filter {$0.selected != false}
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let transition = edit.settings["transition"]?.string ?? "cut"
        let fade = Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5
        guard !clips.isEmpty, clips.count <= 500, [1.0, 1.25, 1.5, 2.0].contains(speed),
              ["cut", "dissolve"].contains(transition), fade.isFinite, 0.1...3 ~= fade,
              clips.allSatisfy({$0.start.isFinite && $0.end.isFinite && 0 <= $0.start && $0.start < $0.end && $0.end <= total}) else {
            throw AppError(message: "בדקו את בחירת הקטעים, הזמנים והגדרות הייצוא.")
        }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {throw AppError(message: "אין ערוץ וידאו.")}
        let natural = try await video.load(.naturalSize), preferred = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
        let displayed = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        let quality = edit.settings["quality"]?.string ?? "1080"
        guard displayed.width.isFinite, displayed.height.isFinite, displayed.width > 0, displayed.height > 0,
              displayed.width <= 16384, displayed.height <= 16384,
              ["720", "1080", "original", "whatsapp"].contains(quality) else {throw AppError(message: "ממדי הסרטון או איכות הייצוא אינם תקינים.")}
        let cap: Double? = ["720", "whatsapp"].contains(quality) ? 720 : quality == "original" ? nil : 1080
        let size = Self.frame(source: displayed, cap: cap, portrait: edit.settings["aspect"]?.string == "9:16")
        let segments = Self.timeline(clips: clips, speed: speed, transition: transition == "cut" ? 0 : fade)
        let length = segments.last!.end
        guard length.isFinite, length > 0, length <= 24 * 3600 else {throw AppError(message: "אורך הסרט הערוך צריך להיות עד 24 שעות.")}
        try LocalStore.checkSpace(required: Int64(length * Double(size.width * size.height) * 30 * 0.35 / 8) + 256 * 1024 * 1024)
        let composition = AVMutableComposition()
        let videos = (0..<2).map {_ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!}
        let original = try await asset.loadTracks(withMediaType: .audio).first
        let muted = edit.settings["muteOriginal"]?.bool ?? false
        let audios = original != nil && !muted ? (0..<2).map {_ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!} : []
        let audioParams = audios.map {AVMutableAudioMixInputParameters(track: $0)}
        let base = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scale = max(size.width / displayed.width, size.height / displayed.height)
        let transform = base.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (size.width - displayed.width * scale) / 2, y: (size.height - displayed.height * scale) / 2))
        let closing = min(1, segments.last!.duration / 2)
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let range = CMTimeRange(start: time(clips[index].start), duration: time(clips[index].duration))
            try videos[segment.track].insertTimeRange(range, of: video, at: time(segment.start))
            videos[segment.track].scaleTimeRange(CMTimeRange(start: time(segment.start), duration: range.duration), toDuration: time(segment.duration))
            if let original, !muted {
                // Camera audio may be slightly shorter than video; preserve silence in the tail.
                let audioRange = try await original.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration.seconds > 0 {
                    let audioStart = segment.start + (available.start.seconds - range.start.seconds) / speed
                    try audios[segment.track].insertTimeRange(available, of: original, at: time(audioStart))
                    audios[segment.track].scaleTimeRange(CMTimeRange(start: time(audioStart), duration: available.duration), toDuration: time(available.duration.seconds / speed))
                }
                let params = audioParams[segment.track]
                params.audioTimePitchAlgorithm = .spectral
                params.setVolume(1, at: time(segment.start))
                if segment.incoming > 0 {params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: time(segment.start), duration: time(segment.incoming)))}
                if segment.outgoing > 0 {params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: time(segment.end - segment.outgoing), duration: time(segment.outgoing)))}
                if index == segments.count - 1 {params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: time(length - closing), duration: time(closing)))}
            }
            await progress(Double(index + 1) / Double(clips.count) * 0.1, "מכינה את העריכה באייפון…")
        }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        func layer(_ track: Int) -> AVMutableVideoCompositionLayerInstruction {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: videos[track]); l.setTransform(transform, at: .zero); return l
        }
        for (index, segment) in segments.enumerated() {
            let passStart = segment.start + segment.incoming, passEnd = segment.end - segment.outgoing
            if passEnd > passStart {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: time(passStart), duration: time(passEnd - passStart))
                let l = layer(segment.track)
                if index == segments.count - 1 {l.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: time(length - closing), duration: time(closing)))}
                instruction.layerInstructions = [l]; instructions.append(instruction)
            }
            if segment.outgoing > 0 {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: time(segment.end - segment.outgoing), duration: time(segment.outgoing))
                let front = layer(segment.track), back = layer(segments[index + 1].track)
                front.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: instruction.timeRange)
                instruction.layerInstructions = [front, back]; instructions.append(instruction)
            }
        }
        var parameters = audioParams
        if edit.settings["useMusic"]?.bool != false && !project.music.isEmpty {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let params = AVMutableAudioMixInputParameters(track: track)
            let volume = Float(edit.settings["musicVolume"]?.string ?? "0.65") ?? 0.65
            let start = Double(edit.settings["musicStart"]?.string ?? "0") ?? 0
            guard volume.isFinite, 0 < volume && volume <= 2, start.isFinite, start >= 0 else {throw AppError(message: "הגדרות מוזיקה לא תקינות.")}
            var cursor = 0.0, item = 0
            while cursor < length - 0.001 {
                try Task.checkCancellation()
                let music = project.music[item % project.music.count]
                let musicAsset = AVURLAsset(url: LocalStore.file(music.file, project: project.id))
                guard let audio = try await musicAsset.loadTracks(withMediaType: .audio).first else {throw AppError(message: "קובץ המוזיקה אינו מכיל שמע.")}
                let audioRange = try await audio.load(.timeRange)
                let offset = item == 0 ? start : 0
                let available = audioRange.duration.seconds - offset
                guard available > 0.01 else {throw AppError(message: "זמן התחלת המוזיקה נמצא מעבר לסוף הקובץ.")}
                let take = min(length - cursor, available)
                try track.insertTimeRange(CMTimeRange(start: time(audioRange.start.seconds + offset), duration: time(take)), of: audio, at: time(cursor))
                cursor += take; item += 1
            }
            params.setVolume(volume, at: .zero)
            params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: time(max(0, length - 3)), duration: time(min(3, length))))
            parameters.append(params)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size; videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        // Standard SDR export is widely playable; AVFoundation handles source decoding.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        // AVFoundation refuses a malformed composition with one opaque code at
        // the end of the export, after the wait. Its own validator names the
        // offending instruction, so ask it up front and say what is wrong.
        let check = CompositionCheck()
        var valid = false
        do {valid = try await videoComposition.isValid(for: composition, timeRange: CMTimeRange(start: .zero, duration: .positiveInfinity), validationDelegate: check)}
        catch is CancellationError {throw CancellationError()}
        catch {check.problems.append(error.localizedDescription)}
        guard valid else {
            let detail = check.problems.isEmpty ? "סיבה לא ידועה" : check.problems.joined(separator: " · ")
            throw AppError(message: "הרכבת הסרט נכשלה: " + detail)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        let preset = quality == "whatsapp" ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset), session.supportedFileTypes.contains(.mp4) else {throw AppError(message: "הייצוא אינו זמין במכשיר זה.")}
        session.outputURL = output; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        session.videoComposition = videoComposition; session.audioMix = mix
        let observer = Task {
            while !Task.isCancelled {await progress(0.1 + Double(session.progress) * 0.9, "מייצאת את הסרט באייפון…"); try? await Task.sleep(for: .milliseconds(250))}
        }
        defer {observer.cancel()}
        try Task.checkCancellation()
        await withTaskCancellationHandler {
            await withCheckedContinuation {continuation in session.exportAsynchronously {continuation.resume()}}
        } onCancel: {session.cancelExport()}
        // The session's own status is what decides the export, not the task's.
        // Asking the task instead threw away a movie that had already finished
        // writing: a short edit of a small frame exports in well under the time
        // it takes anything else to touch the task, and the file on disk was
        // complete before the check that discarded it. Each outcome also names
        // itself now, so a failure here says which one happened.
        switch session.status {
        case .completed: break
        case .cancelled: throw CancellationError()
        default: throw session.error ?? AppError(message: "הייצוא נכשל באייפון.")
        }
        await progress(1, "הסרט מוכן באייפון")
        return length
    }
}

/// Collects why AVFoundation considers a video composition invalid, so the
/// failure can name the instruction instead of a bare error code.
final class CompositionCheck: NSObject, AVVideoCompositionValidationHandling {
    var problems: [String] = []
    // Keep validating after the first complaint: the whole list of flaws is
    // worth more than the first one, and the delegate is the only way to see it.
    private func note(_ text: String) -> Bool {
        if problems.count < 8 {problems.append(text)}
        return problems.count < 8
    }
    private func seconds(_ range: CMTimeRange) -> String {
        String(format: "%.3f-%.3f", range.start.seconds, range.end.seconds)
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        note("ערך לא תקין: \(key)")
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        note("פער ללא הוראה: \(seconds(timeRange))")
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: any AVVideoCompositionInstructionProtocol) -> Bool {
        note("טווח זמן לא תקין: \(seconds(instruction.timeRange))")
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: any AVVideoCompositionInstructionProtocol,
                          layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
        note("ערוץ לא תקין \(layerInstruction.trackID) בטווח \(seconds(instruction.timeRange))")
    }
}
