import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreImage
import UIKit
import OSLog
import SoundAnalysis
import Vision

// Only native Apple frameworks: source files never leave the device.
actor LocalEngine {
    private let logger = Logger(subsystem: "com.rkmotion", category: "MediaPerformance")
    /// The transitions an edit may name, each drawn below in `prepare`;
    /// "smart" picks one of the others for each seam.
    static let transitions = ["cut", "dissolve", "fade", "flash", "slide", "zoom", SmartTransitions.name]
    private var beatCache: [String: [Double]] = [:]
    /// Beats of the song's playing stretch, in movie seconds, worked out once.
    private func songBeats(_ file: URL, start: Double, length: Double) async -> [Double]? {
        let key = "\(file.path)|\(start)|\(length)"
        if let cached = beatCache[key] {return cached}
        guard length > 3, let onsets = try? await Beats.envelope(file, from: start, length: length),
              let grid = Beats.grid(onsets) else {return nil}
        beatCache[key] = grid.times
        return grid.times
    }
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
        // Padding adjacent groups can overlap; merge those windows before
        // splitting, so footage does not appear twice in the default edit.
        var windows: [(Double, Double)] = []
        for group in groups {
            let start = max(0, Double(group.first!) - 2), end = min(duration, Double(group.last!) + 3)
            if let previous = windows.last, start <= previous.1 {
                windows[windows.count - 1].1 = max(previous.1, end)
            } else {windows.append((start, end))}
        }
        let clips = windows.flatMap {window -> [Clip] in
            let start = window.0, end = window.1
            let first = max(0, Int(start)), last = min(scores.count - 1, max(first, Int(ceil(end)) - 1))
            guard end - start >= min(5, duration) else {return []}
            let score = scores[first...last].reduce(0, +) / Double(last - first + 1)
            // Split long activity spans so the editor stays useful for long rides.
            return stride(from: start, to: end, by: 30).map {Clip(start: $0, end: min(end, $0 + 30), score: score)}
        }.sorted {$0.start < $1.start}
        return Edit.capped(clips)
    }
    /// Whether cuts move to the song's beat. Never for a video kept whole:
    /// its one clip is the rider's own edit, and its end is the video's end.
    static func syncsToBeat(_ edit: Edit, project: LocalProject) -> Bool {
        edit.settings["beatSync"]?.bool != false && edit.settings["useMusic"]?.bool != false && !project.music.isEmpty
            && edit.settings["wholeVideo"]?.bool != true && !(edit.settings["wholeVideo"] == nil && project.wholeVideo)
    }
    /// The clips as they will be exported: with each cut moved onto the
    /// beat when that applies. Only the first song is measured, since it is
    /// the one playing from the movie's first frame.
    private func synced(_ clips: [Clip], project: LocalProject, edit: Edit, speed: Double, overlap: Double, total: Double) async -> [Clip] {
        guard Self.syncsToBeat(edit, project: project), let song = project.music.first else {return clips}
        let start = edit.musicStart(for: song.id, first: true)
        let estimate = Self.timeline(clips: clips, speed: speed, transition: overlap).last?.end ?? 0
        // Rounded up to half minutes, so small edits reuse the same beats.
        let window = min(max(0, song.duration - start), ceil((estimate + 15) / 30) * 30)
        guard let beats = await songBeats(LocalStore.file(song.file, project: project.id), start: start, length: window) else {return clips}
        let seams = project.joinsVideos ? project.pieces.dropLast().map(\.end) : []
        return Beats.synced(clips, beats: beats, speed: speed, transition: overlap, sourceDuration: total, seams: seams)
    }
    /// The finished movie's length exactly as `export` will make it, beat
    /// moves included; nil when the edit cannot be exported as it stands.
    func plannedLength(_ project: LocalProject, edit: Edit) async -> Double? {
        let clips = edit.clips.filter {$0.selected != false}
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let transition = edit.settings["transition"]?.string ?? "cut"
        let fade = Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5
        guard !clips.isEmpty, speed > 0, speed.isFinite, project.duration > 0,
              clips.allSatisfy({$0.start.isFinite && $0.end.isFinite && 0 <= $0.start && $0.start < $0.end && $0.end <= project.duration && project.part(for: $0) != nil}) else {return nil}
        let overlap = transition == "cut" ? 0 : (fade.isFinite ? fade : 0.5)
        let planned = await synced(clips, project: project, edit: edit, speed: speed, overlap: overlap, total: project.duration)
        return Self.timeline(clips: planned, speed: speed, transition: overlap).last?.end
    }
    func sourceDimensions(_ source: URL) async throws -> CGSize {
        guard let video = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first else {return .zero}
        let natural = try await video.load(.naturalSize), preferred = try await video.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
        return CGSize(width: abs(bounds.width), height: abs(bounds.height))
    }
    /// One scan's result. `signals` and `reading` are nil when the whole
    /// video is kept as it is and nothing was scanned. `durations` holds
    /// each scanned video's length, in order.
    struct Analysis {
        let duration: Double
        let scores: [Double]
        let clips: [Clip]
        let signals: Signals?
        let reading: ContentReading?
        var durations: [Double] = []
    }
    func analyze(_ source: URL, whole: Bool, progress: @escaping Progress) async throws -> Analysis {
        try await analyze([source], whole: whole, progress: progress)
    }
    /// Scans the videos one after another and reads them as one timeline,
    /// in the order given. Clips never run from one video into the next.
    func analyze(_ sources: [URL], whole: Bool, progress: @escaping Progress) async throws -> Analysis {
        try Task.checkCancellation()
        guard !sources.isEmpty else {throw AppError(message: "בחרו סרטון תקין באורך של עד 24 שעות.")}
        var assets: [AVURLAsset] = [], durations: [Double] = []
        for source in sources {
            let asset = AVURLAsset(url: source)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw AppError(message: "בחרו סרטון תקין באורך של עד 24 שעות.")
            }
            assets.append(asset); durations.append(duration)
        }
        let total = durations.reduce(0, +)
        guard total <= 24 * 3600 else {throw AppError(message: "בחרו סרטון תקין באורך של עד 24 שעות.")}
        let parts = ProjectPart.laid(sources.map(\.lastPathComponent), durations: durations)
        if whole {
            return Analysis(duration: total, scores: [], clips: parts.map {Clip(start: $0.start, end: $0.end)}, signals: nil, reading: nil, durations: durations)
        }
        let scanStarted = Date()
        var measured: [(signals: Signals, start: Double, duration: Double)] = []
        for (index, asset) in assets.enumerated() {
            let part = parts[index], share = part.duration / total, base = part.start / total
            let signals = try await measure(asset, duration: part.duration) {fraction, text in await progress(base + fraction * share, text)}
            measured.append((signals, part.start, part.duration))
        }
        let signals = Signals.joined(measured)
        let reading = ContentReading.read(signals)
        let scores = signals.scores(for: reading.kind)
        logger.info("Analysis completed: sourceSeconds=\(total, privacy: .public), videos=\(sources.count, privacy: .public), elapsedSeconds=\(Date().timeIntervalSince(scanStarted), privacy: .public), kind=\(reading.kind.rawValue, privacy: .public)")
        await progress(1, "הניתוח הושלם באייפון")
        let clips = ProjectPart.fit(Self.ranges(scores: scores, duration: total), into: parts)
        return Analysis(duration: total, scores: scores, clips: clips, signals: signals, reading: reading, durations: durations)
    }
    /// One video's per-second signals: motion from small frames, then what
    /// is in frame, then the sound.
    private func measure(_ asset: AVURLAsset, duration: Double, progress: Progress) async throws -> Signals {
        let count = max(1, Int(ceil(duration)))
        var motion = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        var previous: [UInt8]?
        let frameCount = Int(ceil(duration * 2))
        // Reuse the decoder while keeping only a bounded batch of tiny images.
        // Measure on real HEVC sources before claiming a speed improvement.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = time(0.15)
        generator.requestedTimeToleranceAfter = time(0.15)
        defer {generator.cancelAllCGImageGeneration()}
        for first in stride(from: 0, to: frameCount, by: 16) {
            try Task.checkCancellation()
            let last = min(frameCount, first + 16)
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
            await progress(0.7 * Double(last) / Double(frameCount), "מנתחת תנועה באייפון…")
        }
        for index in motion.indices where counts[index] > 0 {motion[index] /= Double(counts[index])}
        let seen = try await look(asset, duration: duration, count: count, progress: progress)
        let heard = try await loudness(asset, duration: duration, progress: progress)
        return Signals(motion: motion, loudness: heard.loudness, music: heard.music, speech: heard.speech,
                       cheer: heard.cheer, people: seen.people, scenes: seen.scenes)
    }
    /// Looks at a few dozen frames spread over the video: how many people
    /// are in frame, and what kind of place it is. Vision runs on the device;
    /// a frame it cannot read is skipped, and if none can be read both come
    /// back empty so the scan still finishes on motion and sound.
    private func look(_ asset: AVAsset, duration: Double, count: Int, progress: Progress) async throws -> (people: [Double], scenes: [String: Double]) {
        let samples = min(48, max(4, Int(duration / 5)))
        let times = (0..<samples).map {time(min(max(0, duration - 0.05), (Double($0) + 0.5) * duration / Double(samples)))}
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 384, height: 384)
        generator.requestedTimeToleranceBefore = time(1)
        generator.requestedTimeToleranceAfter = time(1)
        defer {generator.cancelAllCGImageGeneration()}
        var counted: [(time: Double, people: Double)] = [], labels: [String: Int] = [:], looked = 0, done = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            done += 1
            if case .success(let requested, let image, _) = result {
                let handler = VNImageRequestHandler(cgImage: image)
                let humans = VNDetectHumanRectanglesRequest()
                humans.upperBodyOnly = false
                if (try? handler.perform([humans])) != nil {
                    counted.append((requested.seconds, Double((humans.results ?? []).filter {$0.confidence > 0.5}.count)))
                }
                let classify = VNClassifyImageRequest()
                if (try? handler.perform([classify])) != nil {
                    looked += 1
                    for label in classify.results ?? [] where label.confidence > 0.3 {labels[label.identifier, default: 0] += 1}
                }
            }
            if done % 4 == 0 {await progress(0.7 + 0.1 * Double(done) / Double(samples), "מזהה מה יש בסרטון…")}
        }
        var people: [Double] = []
        if !counted.isEmpty {
            // Each second takes the count of the nearest looked-at frame.
            people = (0..<count).map {second in
                let at = Double(second) + 0.5
                return counted.min {abs($0.time - at) < abs($1.time - at)}!.people
            }
        }
        let scenes = looked == 0 ? [:] : labels.mapValues {Double($0) / Double(looked)}
        return (people, scenes)
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
    /// A song's loudness in even slices, to draw it while choosing its start.
    static func waveform(_ file: URL, bins: Int = 120) async throws -> [Double] {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, !tracks.isEmpty, bins > 0 else {return []}
        var peaks = [Double](repeating: 0, count: bins)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            // AVFoundation refuses anything under 8 kHz.
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else {return []}
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? AppError(message: "קריאת השמע נכשלה.")}
        defer {reader.cancelReading()}
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard start.isFinite, let block = CMSampleBufferGetDataBuffer(sample) else {continue}
            let size = CMBlockBufferGetDataLength(block)
            var data = [UInt8](repeating: 0, count: size)
            guard data.withUnsafeMutableBytes({CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)}) == kCMBlockBufferNoErr else {continue}
            data.withUnsafeBytes {bytes in
                for (index, value) in bytes.bindMemory(to: Float.self).enumerated() where value.isFinite {
                    let bin = min(bins - 1, max(0, Int((start + Double(index) / 8000) / duration * Double(bins))))
                    peaks[bin] = max(peaks[bin], Double(abs(value)))
                }
            }
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map {$0 / loudest} : peaks
    }
    /// The sound, second by second: how loud, and how sure the built-in
    /// sound classifier is that it hears music, speech, or laughter and
    /// cheering. The classifier's channels stay empty when it is unavailable.
    private func loudness(_ asset: AVAsset, duration: Double, progress: Progress) async throws -> (loudness: [Double], music: [Double], speech: [Double], cheer: [Double]) {
        let count = max(1, Int(ceil(duration)))
        var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {return (sums, [], [], [])}
        let rate = 16000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        let tally = SoundTally(count: count)
        var analyzer: SNAudioStreamAnalyzer?
        if let format, let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            let candidate = SNAudioStreamAnalyzer(format: format)
            if (try? candidate.add(request, withObserver: tally)) != nil {analyzer = candidate}
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
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
                    let floats = bytes.bindMemory(to: Float.self)
                    for (index, value) in floats.enumerated() {
                        let bucket = min(count - 1, max(0, Int(start + Double(index) / rate)))
                        if value.isFinite {sums[bucket] += Double(value * value); counts[bucket] += 1}
                    }
                    if let analyzer, let format, !floats.isEmpty,
                       let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(floats.count)),
                       let channel = buffer.floatChannelData?[0] {
                        buffer.frameLength = AVAudioFrameCount(floats.count)
                        for (index, value) in floats.enumerated() {channel[index] = value.isFinite ? value : 0}
                        analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(start * rate))
                    }
                }
            }
            let second = Int(start)
            if second >= lastProgress + 5 {lastProgress = second; await progress(0.8 + 0.2 * min(1, Double(second) / duration), "מנתחת שמע באייפון…")}
        }
        guard reader.status == .completed else {throw reader.error ?? AppError(message: "פענוח השמע הופסק.")}
        if let analyzer {
            analyzer.completeAnalysis()
            // Late results may still be on their way; the observer says when the last has landed.
            _ = tally.finished.wait(timeout: .now() + 10)
        }
        let heard = tally.snapshot()
        return (sums.indices.map {counts[$0] > 0 ? sqrt(sums[$0] / Double(counts[$0])) : 0}, heard.music, heard.speech, heard.cheer)
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
    struct PreparedEdit {
        let composition: AVMutableComposition
        let video: AVMutableVideoComposition
        let audio: AVMutableAudioMix
        let length: Double
        let preset: String
    }
    /// One video of the edit, read once for all the clips taken from it.
    private struct Source {
        /// Held for as long as the edit is built: a track does not keep its asset alive.
        let asset: AVURLAsset
        let start: Double
        let duration: Double
        let video: AVAssetTrack
        let audio: AVAssetTrack?
        let audioRange: CMTimeRange?
        let preferred: CGAffineTransform
        let bounds: CGRect
        var end: Double {start + duration}
        var displayed: CGSize {CGSize(width: abs(bounds.width), height: abs(bounds.height))}
        /// Upright, scaled to fill `size` and centred in it.
        func transform(filling size: CGSize) -> CGAffineTransform {
            let base = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            let scale = max(size.width / displayed.width, size.height / displayed.height)
            return base.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (size.width - displayed.width * scale) / 2, y: (size.height - displayed.height * scale) / 2))
        }
    }
    private func sources(_ project: LocalProject) async throws -> [Source] {
        var result: [Source] = [], cursor = 0.0
        for file in project.files {
            let asset = AVURLAsset(url: LocalStore.file(file, project: project.id))
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {throw AppError(message: "בדקו את בחירת הקטעים, הזמנים והגדרות הייצוא.")}
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {throw AppError(message: "אין ערוץ וידאו.")}
            let natural = try await video.load(.naturalSize), preferred = try await video.load(.preferredTransform)
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioRange: CMTimeRange?
            if let audio {audioRange = try await audio.load(.timeRange)} else {audioRange = nil}
            result.append(Source(asset: asset, start: cursor, duration: duration, video: video, audio: audio, audioRange: audioRange,
                                 preferred: preferred, bounds: CGRect(origin: .zero, size: natural).applying(preferred)))
            cursor += duration
        }
        return result
    }
    /// `closing` fades the end out; the joined videos shown as the source do not.
    func prepare(_ project: LocalProject, edit: Edit, closing fadesOut: Bool = true, progress: Progress) async throws -> PreparedEdit {
        let sources = try await sources(project)
        let total = sources.last!.end
        var clips = edit.clips.filter {$0.selected != false}
        let speed = Double(edit.settings["speed"]?.string ?? "1") ?? 1
        let transition = edit.settings["transition"]?.string ?? "cut"
        let fade = Double(edit.settings["transitionDuration"]?.string ?? "0.5") ?? 0.5
        // Each clip comes from one video.
        func source(of clip: Clip) -> Int? {
            sources.firstIndex {clip.start >= $0.start - 0.0001 && clip.end <= $0.end + 0.0001}
        }
        guard !clips.isEmpty, clips.count <= Edit.clipLimit, [1.0, 1.25, 1.5, 2.0].contains(speed),
              Self.transitions.contains(transition), fade.isFinite, 0.1...3 ~= fade,
              clips.allSatisfy({$0.start.isFinite && $0.end.isFinite && 0 <= $0.start && $0.start < $0.end && $0.end <= total && source(of: $0) != nil}) else {
            throw AppError(message: "בדקו את בחירת הקטעים, הזמנים והגדרות הייצוא.")
        }
        let displayed = sources[0].displayed
        let quality = edit.settings["quality"]?.string ?? "1080"
        guard displayed.width.isFinite, displayed.height.isFinite, displayed.width > 0, displayed.height > 0,
              displayed.width <= 16384, displayed.height <= 16384,
              sources.allSatisfy({$0.displayed.width > 0 && $0.displayed.height > 0}),
              ["720", "1080", "original", "whatsapp"].contains(quality) else {throw AppError(message: "ממדי הסרטון או איכות הייצוא אינם תקינים.")}
        let cap: Double? = ["720", "whatsapp"].contains(quality) ? 720 : quality == "original" ? nil : 1080
        let size = Self.frame(source: displayed, cap: cap, portrait: edit.settings["aspect"]?.string == "9:16")
        let overlap = transition == "cut" ? 0 : fade
        clips = await synced(clips, project: project, edit: edit, speed: speed, overlap: overlap, total: total)
        try Task.checkCancellation()
        let segments = Self.timeline(clips: clips, speed: speed, transition: overlap)
        // Each seam's own transition, read from the clips around it when the edit asks for smart ones.
        let styles = transition == SmartTransitions.name
            ? SmartTransitions.styles(for: clips, signals: LocalStore.readSignals(project: project.id), kind: project.reading?.kind, pieces: project.pieces)
            : Array(repeating: transition, count: max(0, clips.count - 1))
        // Beat moves stay inside each clip's own video, so this always finds it.
        let from = try clips.map {clip -> Int in
            guard let index = source(of: clip) else {throw AppError(message: "בדקו את בחירת הקטעים, הזמנים והגדרות הייצוא.")}
            return index
        }
        let transforms = sources.map {$0.transform(filling: size)}
        let length = segments.last!.end
        guard length.isFinite, length > 0, length <= 24 * 3600 else {throw AppError(message: "אורך הסרט הערוך צריך להיות עד 24 שעות.")}
        let composition = AVMutableComposition()
        let videos = (0..<2).map {_ in composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!}
        let muted = edit.settings["muteOriginal"]?.bool ?? false
        let audios = sources.contains(where: {$0.audio != nil}) && !muted ? (0..<2).map {_ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!} : []
        let audioParams = audios.map {AVMutableAudioMixInputParameters(track: $0)}
        let closing = fadesOut ? min(1, segments.last!.duration / 2) : 0
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let piece = sources[from[index]]
            // The clip's own seconds inside its video.
            let local = max(0, clips[index].start - piece.start)
            let range = CMTimeRange(start: time(local), duration: time(min(clips[index].duration, piece.duration - local)))
            try videos[segment.track].insertTimeRange(range, of: piece.video, at: time(segment.start))
            videos[segment.track].scaleTimeRange(CMTimeRange(start: time(segment.start), duration: range.duration), toDuration: time(segment.duration))
            if !audios.isEmpty {
                let params = audioParams[segment.track]
                params.audioTimePitchAlgorithm = .spectral
                params.setVolume(1, at: time(segment.start))
            }
            if let original = piece.audio, let audioRange = piece.audioRange, !muted {
                // Camera audio may be slightly shorter than video; preserve silence in the tail.
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration.seconds > 0 {
                    let audioStart = segment.start + (available.start.seconds - range.start.seconds) / speed
                    try audios[segment.track].insertTimeRange(available, of: original, at: time(audioStart))
                    audios[segment.track].scaleTimeRange(CMTimeRange(start: time(audioStart), duration: available.duration), toDuration: time(available.duration.seconds / speed))
                }
                let params = audioParams[segment.track]
                if segment.incoming > 0 {params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: time(segment.start), duration: time(segment.incoming)))}
                if segment.outgoing > 0 {params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: time(segment.end - segment.outgoing), duration: time(segment.outgoing)))}
                if index == segments.count - 1 && closing > 0 {params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: time(length - closing), duration: time(closing)))}
            }
            await progress(Double(index + 1) / Double(clips.count) * 0.1, "מכינה את העריכה באייפון…")
        }
        var instructions: [AVMutableVideoCompositionInstruction] = []
        func layer(_ index: Int) -> AVMutableVideoCompositionLayerInstruction {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: videos[segments[index].track]); l.setTransform(transforms[from[index]], at: .zero); return l
        }
        for (index, segment) in segments.enumerated() {
            let passStart = segment.start + segment.incoming, passEnd = segment.end - segment.outgoing
            if passEnd > passStart {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: time(passStart), duration: time(passEnd - passStart))
                let l = layer(index)
                if index == segments.count - 1 && closing > 0 {l.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: time(length - closing), duration: time(closing)))}
                instruction.layerInstructions = [l]; instructions.append(instruction)
            }
            if segment.outgoing > 0 {
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: time(segment.end - segment.outgoing), duration: time(segment.outgoing))
                let front = layer(index), back = layer(index + 1)
                let transform = transforms[from[index]], incoming = transforms[from[index + 1]]
                let range = instruction.timeRange
                let middle = time(segment.end - segment.outgoing / 2)
                let style = styles[index]
                switch style {
                case "fade", "flash":
                    // Out to a colour, then in from it.
                    if style == "flash" {instruction.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)}
                    front.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: CMTimeRange(start: range.start, end: middle))
                    back.setOpacity(0, at: range.start)
                    back.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: middle, end: range.end))
                case "slide":
                    // The next clip pushes the current one off to the side.
                    front.setTransformRamp(fromStart: transform, toEnd: transform.concatenating(CGAffineTransform(translationX: -size.width, y: 0)), timeRange: range)
                    back.setTransformRamp(fromStart: incoming.concatenating(CGAffineTransform(translationX: size.width, y: 0)), toEnd: incoming, timeRange: range)
                case "zoom":
                    // The current clip rushes towards the viewer as it fades.
                    let grow = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                        .concatenating(CGAffineTransform(scaleX: 1.35, y: 1.35))
                        .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
                    front.setTransformRamp(fromStart: transform, toEnd: transform.concatenating(grow), timeRange: range)
                    front.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                default:
                    front.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: range)
                }
                instruction.layerInstructions = [front, back]; instructions.append(instruction)
            }
        }
        var parameters = audioParams
        if edit.settings["useMusic"]?.bool != false && !project.music.isEmpty {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            let params = AVMutableAudioMixInputParameters(track: track)
            let volume = Float(edit.settings["musicVolume"]?.string ?? "0.65") ?? 0.65
            guard volume.isFinite, 0 < volume && volume <= 2 else {throw AppError(message: "הגדרות מוזיקה לא תקינות.")}
            var cursor = 0.0, item = 0
            while cursor < length - 0.001 {
                try Task.checkCancellation()
                let music = project.music[item % project.music.count]
                let musicAsset = AVURLAsset(url: LocalStore.file(music.file, project: project.id))
                guard let audio = try await musicAsset.loadTracks(withMediaType: .audio).first else {throw AppError(message: "קובץ המוזיקה אינו מכיל שמע.")}
                let audioRange = try await audio.load(.timeRange)
                let offset = edit.musicStart(for: music.id, first: item % project.music.count == 0)
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
        // The composition's duration is the result of AVFoundation's own
        // rounding of the scaled segments, not of the seconds computed above,
        // so the two can disagree by a single tick. AVFoundation then refuses
        // the whole composition over that sliver. Snap the instructions onto
        // the real duration so they cover it edge to edge.
        let span = try await composition.load(.duration)
        var filled = CMTime.zero
        var covering: [AVMutableVideoCompositionInstruction] = []
        for instruction in instructions {
            let end = min(instruction.timeRange.end, span)
            guard filled < end else {continue}
            instruction.timeRange = CMTimeRange(start: filled, end: end)
            covering.append(instruction); filled = end
        }
        guard let tail = covering.last else {throw AppError(message: "לא נותרו קטעים לייצוא.")}
        if filled < span {tail.timeRange = CMTimeRange(start: tail.timeRange.start, end: span)}
        instructions = covering
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
        do {valid = try await videoComposition.isValid(for: composition, timeRange: CMTimeRange(start: .zero, duration: span), validationDelegate: check)}
        catch is CancellationError {throw CancellationError()}
        catch {check.problems.append(error.localizedDescription)}
        guard valid else {
            let detail = check.problems.isEmpty ? "סיבה לא ידועה" : check.problems.joined(separator: " · ")
            throw AppError(message: NSLocalizedString("הרכבת הסרט נכשלה: ", comment: "Composition failure prefix") + detail)
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = parameters
        let preset = quality == "whatsapp" ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        return PreparedEdit(composition: composition, video: videoComposition, audio: mix, length: length, preset: preset)
    }
    /// When the opening title shows: in after a beat, held, then out, all
    /// inside the movie even when it is only a few seconds long.
    static func titleTimes(length: Double) -> (start: Double, end: Double) {
        let start = min(0.4, length * 0.1)
        return (start, min(length - start, max(start + 1, min(4, length * 0.6))))
    }
    /// How visible the opening title is at a moment of the movie, 0 to 1.
    static func titleOpacity(at time: Double, length: Double) -> Double {
        let (start, end) = titleTimes(length: length), fade = min(0.5, (end - start) / 3)
        guard time.isFinite, time > start, time < end else {return 0}
        return min(1, (time - start) / fade, (end - time) / fade)
    }
    /// The opening title as one transparent picture the size of the frame: the
    /// title and a smaller line under it, low on the frame over a shade so it
    /// reads on any footage, right-aligned when it starts in Hebrew.
    static func titleCard(title: String, subtitle: String, size: CGSize) -> CGImage? {
        guard !(title.isEmpty && subtitle.isEmpty), size.width >= 2, size.height >= 2 else {return nil}
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image {context in
            let shadeHeight = size.height * 0.42
            let colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.62).cgColor] as CFArray
            if let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(shade, start: CGPoint(x: 0, y: size.height - shadeHeight), end: CGPoint(x: 0, y: size.height), options: [])
            }
            let short = min(size.width, size.height), margin = short * 0.07
            var bottom = size.height - margin
            func line(_ text: String, points: CGFloat, weight: CGFloat, color: UIColor) {
                guard !text.isEmpty else {return}
                let font = RK.uiFont(points, weight).withSize(points)
                let rtl = text.unicodeScalars.first {CharacterSet.letters.contains($0)}.map {(0x0590...0x08FF).contains($0.value)} ?? false
                let style = NSMutableParagraphStyle()
                style.alignment = rtl ? .right : .left; style.lineBreakMode = .byTruncatingTail
                style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
                let shadow = NSShadow(); shadow.shadowColor = UIColor(white: 0, alpha: 0.45); shadow.shadowBlurRadius = points * 0.15
                let height = ceil(font.lineHeight * 1.15)
                (text as NSString).draw(with: CGRect(x: margin, y: bottom - height, width: size.width - margin * 2, height: height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style, .shadow: shadow], context: nil)
                bottom -= height + points * 0.1
            }
            // Drawn bottom up: the smaller line sits under the title.
            line(subtitle, points: (short * 0.05).rounded(), weight: 500, color: RK.UI.accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
            line(title, points: (short * 0.085).rounded(), weight: 700, color: .white)
        }
        return image.cgImage
    }
    /// The edit ready to play, as immutable copies that any number of player
    /// items can share without one of them changing under another.
    func previewEdit(_ project: LocalProject, edit: Edit) async throws -> PreviewEdit {
        let prepared = try await prepare(project, edit: edit) {_, _ in}
        try Task.checkCancellation()
        guard let composition = prepared.composition.copy() as? AVComposition,
              let video = prepared.video.copy() as? AVVideoComposition,
              let audio = prepared.audio.copy() as? AVAudioMix else {throw AppError(message: "הרכבת הסרט נכשלה: ")}
        return PreviewEdit(composition: composition, video: video, audio: audio)
    }
    /// A project's videos played one after another as they are, with their
    /// own sound, so its timeline's seconds are the player's seconds.
    func joinedSource(_ project: LocalProject) async throws -> PreviewEdit {
        var whole = Edit(clips: project.wholeClips)
        whole.settings["useMusic"] = .flag(false); whole.settings["quality"] = .text("720")
        let prepared = try await prepare(project, edit: whole, closing: false) {_, _ in}
        guard let composition = prepared.composition.copy() as? AVComposition,
              let video = prepared.video.copy() as? AVVideoComposition,
              let audio = prepared.audio.copy() as? AVAudioMix else {throw AppError(message: "הרכבת הסרט נכשלה: ")}
        return PreviewEdit(composition: composition, video: video, audio: audio)
    }
    func preview(_ project: LocalProject, edit: Edit) async throws -> AVPlayerItem {
        try await previewEdit(project, edit: edit).makeItem()
    }
    func export(_ project: LocalProject, edit: Edit, output: URL, progress: @escaping Progress) async throws -> Double {
        let started = Date()
        let prepared = try await prepare(project, edit: edit, progress: progress)
        let size = prepared.video.renderSize
        let opening = edit.openingTitle
        let card = Self.titleCard(title: opening.title, subtitle: opening.subtitle, size: size)
        // A title needs a second file for a moment, so twice the room.
        let movieBytes = Int64(prepared.length * Double(size.width * size.height) * 30 * 0.35 / 8)
        try LocalStore.checkSpace(required: movieBytes * (card == nil ? 1 : 2) + 256 * 1024 * 1024)
        guard let card else {
            try await run(prepared.composition, video: prepared.video, audio: prepared.audio, preset: prepared.preset, length: prepared.length, to: output) {await progress(0.1 + $0 * 0.9, "מייצאת את הסרט באייפון…")}
            return await finish(prepared.length, started: started, progress: progress)
        }
        // The title is laid over the finished movie in a second pass. Core
        // Animation, the usual way, brings the simulator's export down, so
        // nothing could show the title works; Core Image is checked by tests.
        let untitled = output.deletingLastPathComponent().appendingPathComponent("untitled-\(UUID().uuidString).mp4")
        defer {try? FileManager.default.removeItem(at: untitled)}
        try await run(prepared.composition, video: prepared.video, audio: prepared.audio, preset: prepared.preset, length: prepared.length, to: untitled) {await progress(0.1 + $0 * 0.6, "מייצאת את הסרט באייפון…")}
        let movie = AVURLAsset(url: untitled), length = prepared.length
        let overlay = CIImage(cgImage: card)
        let titled = try await AVMutableVideoComposition.videoComposition(with: movie) {request in
            let alpha = Self.titleOpacity(at: request.compositionTime.seconds, length: length)
            guard alpha > 0 else {request.finish(with: request.sourceImage, context: nil); return}
            let faded = overlay.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
            request.finish(with: faded.composited(over: request.sourceImage).cropped(to: request.sourceImage.extent), context: nil)
        }
        titled.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        titled.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        titled.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        try await run(movie, video: titled, audio: nil, preset: prepared.preset, length: prepared.length, to: output) {await progress(0.7 + $0 * 0.3, "מוסיפה את הכותרת…")}
        return await finish(prepared.length, started: started, progress: progress)
    }
    private func finish(_ length: Double, started: Date, progress: Progress) async -> Double {
        await progress(1, "הסרט מוכן באייפון")
        logger.info("Export completed: outputSeconds=\(length, privacy: .public), elapsedSeconds=\(Date().timeIntervalSince(started), privacy: .public), thermalState=\(ProcessInfo.processInfo.thermalState.rawValue, privacy: .public)")
        return length
    }
    private func run(_ asset: AVAsset, video: AVVideoComposition, audio: AVAudioMix?, preset: String, length: Double, to output: URL, progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset), session.supportedFileTypes.contains(.mp4) else {throw AppError(message: "הייצוא אינו זמין במכשיר זה.")}
        session.outputURL = output; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        session.videoComposition = video; session.audioMix = audio
        // The movie ends where the edit ends. Without this the iOS 27
        // simulator wrote a file longer than the edit, with no picture at the
        // end, which the length shown to the rider would not match.
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        let observer = Task {
            while !Task.isCancelled {await progress(Double(session.progress)); try? await Task.sleep(for: .milliseconds(250))}
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
        note(String(format: NSLocalizedString("ערך לא תקין: %@", comment: "Invalid composition value"), key))
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        note(String(format: NSLocalizedString("פער ללא הוראה: %@", comment: "Uncovered composition range"), seconds(timeRange)))
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction: any AVVideoCompositionInstructionProtocol) -> Bool {
        note(String(format: NSLocalizedString("טווח זמן לא תקין: %@", comment: "Invalid instruction range"), seconds(instruction.timeRange)))
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction: any AVVideoCompositionInstructionProtocol,
                          layerInstruction: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool {
        note(String(format: NSLocalizedString("ערוץ לא תקין %@ בטווח %@", comment: "Invalid composition track"), "\(layerInstruction.trackID)", seconds(instruction.timeRange)))
    }
}

/// Collects the sound classifier's verdicts into one value per second for
/// each of the three sounds the recipes use. Results may arrive on the
/// analyzer's own thread, so every access takes the lock.
final class SoundTally: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var music: [Double], speech: [Double], cheer: [Double]
    private var heard = false
    /// Signaled once the request completes or fails, so no result is missed.
    let finished = DispatchSemaphore(value: 0)
    init(count: Int) {
        music = [Double](repeating: 0, count: count); speech = music; cheer = music
    }
    static func channel(_ identifier: String) -> Signals.Channel? {
        if identifier == "music" || identifier == "singing" {return .music}
        if identifier == "speech" || identifier == "conversation" {return .speech}
        let cheering = ["laugh", "giggl", "chuckle", "cheer", "applause", "clapping", "crowd"]
        return cheering.contains {identifier.contains($0)} ? .cheer : nil
    }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else {return}
        let start = result.timeRange.start.seconds, end = CMTimeRangeGetEnd(result.timeRange).seconds
        guard start.isFinite, end.isFinite else {return}
        var found: [Signals.Channel: Double] = [:]
        for item in result.classifications {
            if let channel = Self.channel(item.identifier) {found[channel] = max(found[channel] ?? 0, item.confidence)}
        }
        lock.lock(); defer {lock.unlock()}
        heard = true
        let count = music.count
        guard count > 0 else {return}
        let first = min(count - 1, max(0, Int(start))), last = min(count - 1, max(first, Int(ceil(end)) - 1))
        for second in first...last {
            music[second] = max(music[second], found[.music] ?? 0)
            speech[second] = max(speech[second], found[.speech] ?? 0)
            cheer[second] = max(cheer[second], found[.cheer] ?? 0)
        }
    }
    func requestDidComplete(_ request: SNRequest) {finished.signal()}
    func request(_ request: SNRequest, didFailWithError error: Error) {finished.signal()}
    /// Empty channels when the classifier never answered, so the recipes
    /// leave them out instead of reading silence.
    func snapshot() -> (music: [Double], speech: [Double], cheer: [Double]) {
        lock.lock(); defer {lock.unlock()}
        return heard ? (music, speech, cheer) : ([], [], [])
    }
}
