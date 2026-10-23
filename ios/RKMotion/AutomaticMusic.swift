import Foundation
import AVFoundation

/// An original instrumental, generated in bounded audio blocks. It is a DSP
/// composer selected by the content recipe, not a claimed generative music
/// model. It makes the automatic flow usable offline without a music picker.
enum AutomaticMusic {
    static let name = "automatic-score-v1.caf"
    static func tempo(kind: ContentKind, style: AutomaticStyle) -> Double {
        if style == .cinematic || style == .family || kind == .talk {return 84}
        return style == .action || kind == .action || kind == .sports ? 128 : 104
    }
    static func make(kind: ContentKind, style: AutomaticStyle, seconds: Double, at url: URL) async throws {
        guard seconds.isFinite, 0.2...1800 ~= seconds else {throw CocoaError(.fileWriteInvalidFileName)}
        let rate = 44100.0, bpm = tempo(kind: kind, style: style)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096), let samples = buffer.floatChannelData?[0] else {throw CocoaError(.fileWriteUnknown)}
        let partial = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        defer {try? FileManager.default.removeItem(at: partial)}
        let file = try AVAudioFile(forWriting: partial, settings: format.settings)
        let count = Int((seconds * rate).rounded()), beat = 60 / bpm
        let notes = [130.8128, 103.8262, 155.5635, 116.5409]
        var noise: UInt64 = 8675309
        for offset in stride(from: 0, to: count, by: 4096) {
            try Task.checkCancellation()
            let length = min(4096, count - offset)
            buffer.frameLength = AVAudioFrameCount(length)
            for i in 0..<length {
                let t = Double(offset + i) / rate, pulse = t.truncatingRemainder(dividingBy: beat)
                let chord = notes[min(3, Int(t / (beat * 8)) % 4)]
                let build = 0.45 + 0.55 * min(1, t / max(1, seconds * 0.55))
                let pad = (sin(2 * .pi * chord * t) + 0.5 * sin(2 * .pi * chord * 1.5 * t)) * 0.11
                let bass = sin(2 * .pi * chord / 2 * t) * exp(-pulse * 7) * 0.14
                let kick = sin(2 * .pi * (48 * pulse + 5 * (1 - exp(-pulse * 35)))) * exp(-pulse * 19) * 0.2
                noise = noise &* 6364136223846793005 &+ 1
                let random = Double(noise >> 40) / Double(1 << 24) * 2 - 1
                let hatPulse = t.truncatingRemainder(dividingBy: beat / 2)
                let hat = random * exp(-hatPulse * 100) * 0.035
                let fade = min(1, t / 1.5, max(0, (seconds - t) / 3))
                samples[i] = Float((pad + build * (bass + kick + hat)) * fade)
            }
            try file.write(from: buffer)
            await Task.yield()
        }
        try Task.checkCancellation()
        // The destination is created only after a complete score is available.
        if FileManager.default.fileExists(atPath: url.path) {try FileManager.default.removeItem(at: url)}
        try FileManager.default.moveItem(at: partial, to: url)
    }
}
