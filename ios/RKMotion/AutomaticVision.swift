import Foundation
import AVFoundation
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AutomaticVision {
    /// On newer SDKs use actual image attachments to the explicitly local
    /// system model. Older builds keep the measured events, never call PCC.
    static func refine(_ events: [AutomaticEvent], project: LocalProject,
                       progress: @escaping LocalEngine.Progress) async throws -> [AutomaticEvent] {
        #if compiler(>=6.4) && canImport(FoundationModels)
        if #available(iOS 27.0, *), SystemLanguageModel.default.isAvailable {
            var result = events
            let indices = events.indices.sorted {events[$0].score > events[$1].score}.prefix(4)
            for (position, index) in indices.enumerated() {
                try Task.checkCancellation()
                let event = result[index]
                guard let part = project.pieces.first(where: {$0.file == event.file}) else {continue}
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LocalStore.file(event.file, project: project.id)))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 448, height: 448)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
                defer {generator.cancelAllCGImageGeneration()}
                let times = [event.start, event.peak, max(event.start, event.end - 0.1)]
                var images: [CGImage] = []
                for time in times {
                    if let image = try? await generator.image(at: CMTime(seconds: max(0, time - part.start), preferredTimescale: 600)).image {images.append(image)}
                }
                guard images.count == 3 else {continue}
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: "Analyze these three video frames in chronological order. Report only visible evidence. Do not infer speed, height, identity, location or feelings. Prefer unknown when the evidence is insufficient.")
                do {
                    let answer = try await session.respond(generating: Assessment.self, options: GenerationOptions(samplingMode: .greedy)) {
                        "Beginning, middle and end of the candidate event. Is an action visibly unfinished at the last frame? Is its preparation missing at the first frame?"
                        Attachment(images[0])
                        Attachment(images[1])
                        Attachment(images[2])
                    }
                    try Task.checkCancellation()
                    result[index].visualKind = answer.content.kind.rawValue
                    // At most two seconds each way, always within this source.
                    if answer.content.preparationMissing {result[index].start = max(part.start, event.start - 2)}
                    if answer.content.actionUnfinished {result[index].end = min(part.end, event.end + 2)}
                } catch is CancellationError {throw CancellationError()}
                catch { /* Model not ready/guardrail/context failure: preserve measured evidence. */ }
                await progress(Double(position + 1) / Double(indices.count), NSLocalizedString("בודק את תחילת הרגע ואת הסיום שלו…", comment: "Local visual assessment"))
            }
            return result
        }
        #endif
        return events
    }
    #if compiler(>=6.4) && canImport(FoundationModels)
    @available(iOS 27.0, *)
    @Generable enum Kind: String {case movement, jump, turn, dancing, people, animal, landscape, unknown}
    @available(iOS 27.0, *)
    @Generable struct Assessment {
        var kind: Kind
        var preparationMissing: Bool
        var actionUnfinished: Bool
    }
    #endif

    /// Compare corresponding image content, not filenames or dates. A minimum
    /// match margin rejects ambiguous views before offering an automatic replay.
    struct Match: Equatable {
        var leftTime: Double
        var rightTime: Double
        var distance: Float
    }
    static func accepted(best: Float, runnerUp: Float) -> Bool {
        best.isFinite && runnerUp.isFinite && best < 0.35 && runnerUp - best > 0.08
    }
    static func match(_ left: URL, _ right: URL) async throws -> Match? {
        func prints(_ file: URL) async throws -> [(Double, VNFeaturePrintObservation)] {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0.2 else {return []}
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 384, height: 384)
            defer {generator.cancelAllCGImageGeneration()}
            var output: [(Double, VNFeaturePrintObservation)] = []
            for index in 0..<10 {
                try Task.checkCancellation()
                let time = min(duration - 0.1, (Double(index) + 0.5) / 10 * duration)
                guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else {continue}
                let request = VNGenerateImageFeaturePrintRequest()
                try VNImageRequestHandler(cgImage: image).perform([request])
                if let observation = request.results?.first {output.append((time, observation))}
            }
            return output
        }
        let a = try await prints(left), b = try await prints(right)
        var matches: [Match] = []
        for first in a {for second in b {
            try Task.checkCancellation()
            var distance: Float = 0
            try first.1.computeDistance(&distance, to: second.1)
            matches.append(Match(leftTime: first.0, rightTime: second.0, distance: distance))
        }}
        matches.sort {$0.distance < $1.distance}
        guard let best = matches.first else {return nil}
        // Adjacent samples of the same match are not independent alternatives.
        let alternative = matches.first {abs($0.leftTime - best.leftTime) > 3 || abs($0.rightTime - best.rightTime) > 3}
        guard accepted(best: best.distance, runnerUp: alternative?.distance ?? 1) else {return nil}
        return best
    }
}
