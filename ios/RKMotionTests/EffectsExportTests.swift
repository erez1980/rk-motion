import XCTest
import AVFoundation
@testable import RKMotion

/// Every effect of the style sheet, alone and all together, through a real
/// export of a video with its own sound and a song with a clear beat.
final class EffectsExportTests: XCTestCase {
    func testEveryEffectExports() async throws {
        var project = LocalProject(name: "effects fixture", source: "source.mov")
        let folder = LocalStore.folder(project.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {try? FileManager.default.removeItem(at: folder)}
        let seconds = 12
        let silent = folder.appendingPathComponent("silent.mov"), voice = folder.appendingPathComponent("voice.wav")
        try await UITestFixture.makeRide(silent, seconds: seconds)
        try writeWave(voice, seconds: Double(seconds), beat: nil)
        try await merge(video: silent, audio: voice, into: LocalStore.file(project.source, project: project.id), seconds: Double(seconds))
        try writeWave(folder.appendingPathComponent("song.wav"), seconds: 40, beat: 0.5)
        project.duration = Double(seconds); project.analyzed = true
        project.music = [LocalMusic(file: "song.wav", name: "song", duration: 40)]
        project.scores = (0..<seconds).map {[0.3, 0.9, 0.5, 0.7][$0 % 4]}
        project.reading = ContentReading(detected: .action, kind: .action, musicShare: 0, speechShare: 0, cheerShare: 0, people: 0, motion: 0.7, outdoors: 0.5)

        var base = Edit(clips: [Clip(start: 0.5, end: 3.5, score: 0.6), Clip(start: 4, end: 7.5, score: 0.8), Clip(start: 8, end: 11.5, score: 0.7)])
        base.settings["aspect"] = .text("9:16")
        base.settings["transition"] = .text("dissolve")
        base.settings["transitionDuration"] = .text("0.5")
        let cases: [(String, [String: Setting])] = [
            ("plain", [:]),
            ("slow peak x2", ["slowMode": .text("peak")]),
            ("slow each x4 3s", ["slowMode": .text("each"), "slowRate": .text("4"), "slowLength": .text("3")]),
            ("speed ramp", ["slowMode": .text("each"), "speedRamp": .flag(true)]),
            ("hook", ["hook": .flag(true)]),
            ("beat zoom", ["beatZoom": .flag(true)]),
            ("whoosh", ["whoosh": .flag(true)]),
            ("beat sync", ["beatSync": .flag(true)]),
            ("smart transitions", ["transition": .text(SmartTransitions.name)]),
            ("speed 1.5", ["speed": .text("1.5")]),
            ("everything", ["slowMode": .text("each"), "slowRate": .text("3"), "slowLength": .text("1.5"), "speedRamp": .flag(true),
                            "hook": .flag(true), "beatZoom": .flag(true), "whoosh": .flag(true), "transition": .text(SmartTransitions.name)]),
        ]
        let engine = LocalEngine()
        var failures: [String] = []
        for (name, settings) in cases {
            var edit = base
            edit.settings.merge(settings) {$1}
            let output = folder.appendingPathComponent("effects-\(failures.count)-\(UUID().uuidString).mp4")
            do {
                let length = try await engine.export(project, edit: edit, output: output) {_, _ in}
                let written = try await AVURLAsset(url: output).load(.duration).seconds
                if abs(written - length) > 0.15 {failures.append("\(name): wrote \(written) s for a \(length) s movie")}
                print("EFFECTS: \(name) exported \(length) s")
            } catch {
                failures.append("\(name): \(Self.describe(error))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// An error and every error under it, with domain and code: AVFoundation's
    /// own message says only that the operation could not be completed.
    static func describe(_ error: Error) -> String {
        var parts: [String] = [], current: NSError? = error as NSError
        while let found = current, parts.count < 5 {
            parts.append("\(found.domain) \(found.code) \(found.localizedDescription) \(found.localizedFailureReason ?? "")")
            current = found.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " <- ")
    }
    /// Mono 16-bit sound at 16 kHz: a soft tone, with a click every `beat` seconds when given.
    private func writeWave(_ url: URL, seconds: Double, beat: Double?) throws {
        let rate = 16000, count = Int(seconds * Double(rate))
        var data = Data()
        func text(_ s: String) {data.append(contentsOf: s.utf8)}
        func word(_ n: UInt16) {data.append(UInt8(n & 255)); data.append(UInt8(n >> 8))}
        func long(_ n: UInt32) {word(UInt16(n & 65535)); word(UInt16(n >> 16))}
        text("RIFF"); long(UInt32(36 + count * 2)); text("WAVEfmt "); long(16); word(1); word(1); long(UInt32(rate)); long(UInt32(rate * 2)); word(2); word(16)
        text("data"); long(UInt32(count * 2))
        for index in 0..<count {
            let t = Double(index) / Double(rate)
            var value = sin(t * 2 * .pi * 220) * 2500
            if let beat {
                let since = t.truncatingRemainder(dividingBy: beat)
                if since < 0.04 {value += sin(t * 2 * .pi * 90) * 20000 * (1 - since / 0.04)}
            }
            word(UInt16(bitPattern: Int16(max(-32000, min(32000, value)))))
        }
        try data.write(to: url)
    }
    private func merge(video: URL, audio: URL, into output: URL, seconds: Double) async throws {
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let videoTracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)
        let audioTracks = try await AVURLAsset(url: audio).loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first), audioTrack = try XCTUnwrap(audioTracks.first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: audioTrack, at: .zero)
        // Copied as they are: re-encoding the generated sound failed on the simulator (-12780).
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        session.outputURL = output; session.outputFileType = .mov
        await withCheckedContinuation {done in session.exportAsynchronously {done.resume()}}
        XCTAssertEqual(session.status, .completed, session.error.map {Self.describe($0)} ?? "")
    }
}
