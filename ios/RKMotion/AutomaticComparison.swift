import Foundation
import AVFoundation

/// A conservative visual replay: the matched source moments play side by
/// side. It is not a 3D reconstruction or a claim of identical GPS position.
enum AutomaticComparison {
    static func export(left: URL, right: URL, match: AutomaticVision.Match, output: URL, alternating: Bool = false) async throws -> Double {
        let assets = [AVURLAsset(url: left), AVURLAsset(url: right)]
        var lengths: [Double] = [], sources: [AVAssetTrack] = []
        for asset in assets {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0.2, let track = try await asset.loadTracks(withMediaType: .video).first else {throw CocoaError(.fileReadCorruptFile)}
            lengths.append(duration); sources.append(track)
        }
        let anchors = [match.leftTime, match.rightTime]
        guard anchors.allSatisfy({$0.isFinite && $0 >= 0}), anchors[0] < lengths[0], anchors[1] < lengths[1] else {throw CocoaError(.fileReadCorruptFile)}
        // Equal pre-roll places both matched anchors on the exact same frame.
        let before = min(3, anchors[0], anchors[1])
        let after = min(5, lengths[0] - anchors[0], lengths[1] - anchors[1])
        let length = before + after
        let composition = AVMutableComposition()
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        var layers: [AVMutableVideoCompositionLayerInstruction] = []
        for index in 0..<2 {
            try Task.checkCancellation()
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {throw CocoaError(.fileWriteUnknown)}
            let range = CMTimeRange(start: CMTime(seconds: anchors[index] - before, preferredTimescale: 600), duration: instruction.timeRange.duration)
            try target.insertTimeRange(range, of: sources[index], at: .zero)
            let natural = try await sources[index].load(.naturalSize), preferred = try await sources[index].load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(preferred)
            guard bounds.width > 0, bounds.height > 0 else {throw CocoaError(.fileReadCorruptFile)}
            let pane: CGFloat = alternating ? 1080 : 540
            let scale = min(pane / bounds.width, 1080 / bounds.height)
            let transform = preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (alternating ? 0 : CGFloat(index) * pane) + (pane - bounds.width * scale) / 2, y: (1080 - bounds.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: target)
            layer.setTransform(transform, at: .zero); layers.append(layer)
            if index == 0, let audio = try await assets[index].loadTracks(withMediaType: .audio).first,
               let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let available = CMTimeRangeGetIntersection(range, otherRange: try await audio.load(.timeRange))
                if available.duration.seconds > 0 {try sound.insertTimeRange(available, of: audio, at: CMTimeSubtract(available.start, range.start))}
            }
        }
        instruction.layerInstructions = layers
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: 1080, height: 1080); video.frameDuration = CMTime(value: 1, timescale: 30)
        if alternating {
            var cuts: [AVMutableVideoCompositionInstruction] = []
            for start in stride(from: 0.0, to: length, by: 2) {
                let cut = AVMutableVideoCompositionInstruction()
                cut.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: min(2, length - start), preferredTimescale: 600))
                cut.layerInstructions = [layers[Int(start / 2) % 2]]
                cut.backgroundColor = CGColor(gray: 0, alpha: 1)
                cuts.append(cut)
            }
            video.instructions = cuts
        } else {video.instructions = [instruction]}
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {throw CocoaError(.fileWriteUnknown)}
        session.videoComposition = video; session.outputURL = output; session.outputFileType = .mp4; session.timeRange = instruction.timeRange
        try await withTaskCancellationHandler {
            await session.export()
            try Task.checkCancellation()
            guard session.status == .completed else {throw session.error ?? CocoaError(.fileWriteUnknown)}
        } onCancel: {session.cancelExport()}
        try await AutomaticStore.validateMovie(output, expected: length)
        return length
    }
}
