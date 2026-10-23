import Foundation
import AVFoundation

enum AutomaticMulticam {
    struct Pair {
        var reference: LocalProject
        var match: AutomaticVision.Match
        var correlation: Double
    }
    /// Audio-backed synchronization, independent of a similar-looking scene.
    /// First release deliberately bounds supported sources to ten minutes and
    /// offsets to thirty seconds; unsupported material is not fake-aligned.
    static func find(_ current: LocalProject, references: [LocalProject]) async throws -> Pair? {
        func envelope(_ project: LocalProject) async throws -> [Double]? {
            let file = LocalStore.file(project.source, project: project.id)
            let duration = try await AVURLAsset(url: file).load(.duration).seconds
            guard duration.isFinite, 3...600 ~= duration else {return nil}
            return try await LocalEngine.waveform(file, bins: max(30, Int((duration * 10).rounded())))
        }
        guard let first = try await envelope(current), !first.isEmpty else {return nil}
        let fileDuration = try await AVURLAsset(url: LocalStore.file(current.source, project: current.id)).load(.duration).seconds
        var best: Pair?
        for reference in references.prefix(5) {
            try Task.checkCancellation()
            guard let second = try await envelope(reference), let alignment = AutomaticSync.align(first, second, rate: 10) else {continue}
            let otherDuration = try await AVURLAsset(url: LocalStore.file(reference.source, project: reference.id)).load(.duration).seconds
            let overlapStart = max(0, alignment.offset), overlapEnd = min(fileDuration, otherDuration + alignment.offset)
            guard overlapEnd - overlapStart >= 3 else {continue}
            let peak = current.scores.enumerated().filter {Double($0.offset) >= overlapStart && Double($0.offset) < overlapEnd}
                .max {$0.element < $1.element}.map {Double($0.offset) + 0.5} ?? (overlapStart + overlapEnd) / 2
            let anchor = min(overlapEnd - 0.1, max(overlapStart, peak))
            let pair = Pair(reference: reference, match: .init(leftTime: anchor, rightTime: anchor - alignment.offset, distance: 0), correlation: alignment.correlation)
            if best == nil || pair.correlation > best!.correlation {best = pair}
        }
        return best
    }
}
