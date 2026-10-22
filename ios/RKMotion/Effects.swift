import Foundation
import AVFoundation

/// The clips exactly as the movie plays them: slow motion and its ramps,
/// then the opening hook. Export, preview, the planned length and the
/// length picker all go through this one shaping.
enum MovieShape {
    static func shaped(_ clips: [Clip], scores: [Double], settings: [String: Setting]) -> [Clip] {
        Hook.added(SlowMotion.shaped(clips, scores: scores, settings: settings), scores: scores, settings: settings)
    }
}

/// Two seconds of the movie's strongest moment played first, as a teaser
/// that stops the thumb before the story starts.
enum Hook {
    static let length = 2.0
    static func isOn(_ settings: [String: Setting]) -> Bool {
        settings["hook"]?.bool == true && settings["wholeVideo"]?.bool != true
    }
    static func added(_ clips: [Clip], scores: [Double], settings: [String: Setting]) -> [Clip] {
        guard isOn(settings), clips.count > 1, clips.count < Edit.clipLimit,
              let peak = Highlights.peak(clips, scores: scores) else {return clips}
        let source = clips[peak.clip]
        let start = max(source.start, min(peak.time - length / 2, source.end - length))
        let end = min(source.end, start + length)
        guard end - start >= 1 else {return clips}
        var teaser = Clip(start: start, end: end, score: source.score)
        teaser.uid = source.uid + "-hook"
        return [teaser] + clips
    }
}

/// A quick push in on the song's beats: every other beat, never closer
/// than `gap` seconds, none in the first and last second.
enum BeatPunch {
    static let scale: CGFloat = 1.07, span = 0.3, gap = 0.9
    static func times(_ beats: [Double], length: Double) -> [Double] {
        var chosen: [Double] = []
        for (index, beat) in beats.enumerated() where index % 2 == 0 && beat >= 1 && beat <= length - 1 {
            if let last = chosen.last, beat - last < gap {continue}
            chosen.append(beat)
        }
        return chosen
    }
}

/// A soft whoosh made on the device: noise swept up and down through a
/// band-pass filter, under each seam that has a transition.
enum Whoosh {
    static let seconds = 0.7, rate = 44100.0
    static let volume: Float = 0.5
    /// Where each whoosh starts so its middle meets the seam, skipping any
    /// that would overlap the one before or run past the movie.
    static func places(seams: [Double], length: Double) -> [Double] {
        var free = 0.0, places: [Double] = []
        for seam in seams.sorted() {
            let at = seam - seconds / 2
            guard at >= free, at + seconds <= length else {continue}
            places.append(at); free = at + seconds
        }
        return places
    }
    static func samples() -> [Float] {
        let count = Int(seconds * rate)
        var low = 0.0, band = 0.0, out: [Float] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(count)
            let shape = pow(sin(.pi * t), 2)
            let centre = 300 + 2700 * sin(.pi * t)
            let f = 2 * sin(.pi * centre / rate)
            let noise = Double.random(in: -1...1)
            // A state-variable filter: the band output is the swept noise.
            low += f * band
            let high = noise - low - 0.7 * band
            band += f * high
            out.append(Float(band * shape))
        }
        let peak = out.map(abs).max() ?? 0
        return peak > 0 ? out.map {$0 / peak * 0.9} : out
    }
    /// The whoosh as a sound file, made once and kept in the caches.
    static func file() throws -> URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("rk-whoosh-1.caf")
        if FileManager.default.fileExists(atPath: url.path) {return url}
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw AppError(message: "קריאת השמע נכשלה.")
        }
        let values = samples()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)),
              let channel = buffer.floatChannelData?[0] else {throw AppError(message: "קריאת השמע נכשלה.")}
        buffer.frameLength = AVAudioFrameCount(values.count)
        for (index, value) in values.enumerated() {channel[index] = value}
        let partial = url.deletingLastPathComponent().appendingPathComponent("rk-whoosh-\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: partial, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
