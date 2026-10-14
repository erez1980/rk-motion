import Foundation
import AVFoundation

/// Finds a song's beat and lands the movie's cuts on it, on the iPhone.
enum Beats {
    /// Envelope frames per second: 10 ms, finer than a cut can be seen.
    static let rate = 100.0

    /// How sharply the sound rises in each 10 ms of `length` seconds from
    /// `start`. A drum hit is a sudden rise, so the beat lives in these peaks.
    static func envelope(_ file: URL, from start: Double, length: Double) async throws -> [Double] {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, length > 0, start >= 0 else {return []}
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: length, preferredTimescale: 600))
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else {return []}
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? AppError(message: "קריאת השמע נכשלה.")}
        defer {reader.cancelReading()}
        let frame = 80 // 10 ms at 8 kHz
        var energy = [Double](repeating: 0, count: Int(ceil(length * rate)) + 1)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds - start
            guard time.isFinite, let block = CMSampleBufferGetDataBuffer(sample) else {continue}
            let size = CMBlockBufferGetDataLength(block)
            var data = [UInt8](repeating: 0, count: size)
            guard data.withUnsafeMutableBytes({CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)}) == kCMBlockBufferNoErr else {continue}
            let first = Int((time * 8000).rounded())
            data.withUnsafeBytes {bytes in
                for (index, value) in bytes.bindMemory(to: Float.self).enumerated() where value.isFinite {
                    let slot = (first + index) / frame
                    if slot >= 0 && slot < energy.count {energy[slot] += Double(value * value)}
                }
            }
        }
        return onsets(energy)
    }

    /// Rises in loudness, with the steady level of the passage taken away.
    static func onsets(_ energy: [Double]) -> [Double] {
        guard energy.count > 2 else {return []}
        let level = energy.map {log(1 + 1000 * $0)}
        var rise = [Double](repeating: 0, count: level.count)
        for index in 1..<level.count {rise[index] = max(0, level[index] - level[index - 1])}
        let reach = 25
        return rise.indices.map {index in
            let window = rise[max(0, index - reach)...min(rise.count - 1, index + reach)]
            return max(0, rise[index] - window.reduce(0, +) / Double(window.count))
        }
    }

    /// The beat as a period and the times it falls on, in seconds from the
    /// envelope's start. Tempos from 70 to 180 BPM are considered, leaning
    /// towards 120 so a song is not read at half or double its speed.
    static func grid(_ onsets: [Double]) -> (period: Double, times: [Double])? {
        let shortest = Int(rate * 60 / 180), longest = Int(rate * 60 / 70)
        guard onsets.count > longest * 3, onsets.contains(where: {$0 > 0}) else {return nil}
        func correlation(_ lag: Int) -> Double {
            var sum = 0.0
            for index in 0..<(onsets.count - lag) {sum += onsets[index] * onsets[index + lag]}
            return sum / Double(onsets.count - lag)
        }
        let scores = (shortest...longest).map {lag -> Double in
            let octaves = log2(Double(lag) / (rate * 0.5))
            return correlation(lag) * exp(-0.5 * pow(octaves / 0.9, 2))
        }
        guard let best = scores.indices.max(by: {scores[$0] < scores[$1]}), scores[best] > 0 else {return nil}
        // A parabola through the peak and its neighbours places it between frames.
        var lag = Double(shortest + best)
        if best > 0, best < scores.count - 1 {
            let left = scores[best - 1], middle = scores[best], right = scores[best + 1]
            let curve = left - 2 * middle + right
            if curve < 0 {lag += 0.5 * (left - right) / curve}
        }
        // The phase is where beats at this period collect the most rises.
        var bestPhase = 0, bestScore = -1.0
        for phase in 0..<Int(lag.rounded()) {
            var score = 0.0, position = Double(phase)
            while Int(position.rounded()) < onsets.count {
                let center = Int(position.rounded())
                score += onsets[max(0, center - 1)...min(onsets.count - 1, center + 1)].max() ?? 0
                position += lag
            }
            if score > bestScore {bestScore = score; bestPhase = phase}
        }
        var times: [Double] = [], position = Double(bestPhase)
        while position < Double(onsets.count) {times.append(position / rate); position += lag}
        return (lag / rate, times)
    }

    /// Moves each cut onto the nearest beat by shortening the clip before it,
    /// or lengthening it when the source has room. `beats` are movie seconds.
    /// A clip never drops below `minimum` seconds on screen.
    static func synced(_ clips: [Clip], beats: [Double], speed: Double, transition: Double, sourceDuration: Double, minimum: Double = 1) -> [Clip] {
        guard clips.count > 0, beats.count > 1, speed > 0 else {return clips}
        var result = clips
        for index in result.indices {
            // Two passes: a shorter clip can also shorten its transition.
            for _ in 0..<2 {
                let segments = LocalEngine.timeline(clips: result, speed: speed, transition: transition)
                let cut = index + 1 < segments.count ? segments[index + 1].start + segments[index + 1].incoming / 2 : segments[index].end
                guard cut <= (beats.last ?? 0) + 0.001 else {return result}
                let earlier = beats.last {$0 <= cut + 0.0001}, later = beats.first {$0 > cut + 0.0001}
                let onScreen = result[index].duration / speed
                func fits(_ beat: Double?) -> Bool {
                    guard let beat else {return false}
                    let end = result[index].end + (beat - cut) * speed
                    return onScreen + beat - cut >= minimum && end <= sourceDuration && end > result[index].start
                }
                let options = [earlier, later].filter(fits).compactMap {$0}
                guard let target = options.min(by: {abs($0 - cut) < abs($1 - cut)}), abs(target - cut) > 0.005 else {break}
                result[index].end += (target - cut) * speed
            }
        }
        return result
    }
}
