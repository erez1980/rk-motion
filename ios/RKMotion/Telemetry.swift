import Foundation
import AVFoundation
import UIKit
import CoreImage

/// Speed, height and distance from the GPS a GoPro records inside its video
/// files, shown on the movie the way a ride computer would.
enum Telemetry {
    /// One GPS reading at a ride second: metres a second, metres, metres so far.
    struct Sample: Equatable {
        var time: Double
        var speed: Double
        var altitude: Double
        var distance: Double = 0
    }
    /// What the overlay shows: km/h, metres, kilometres.
    struct Readout: Hashable {
        let speed: Int
        let altitude: Int
        let distance: Double
    }
    /// The overlay at one movie second; nil where the ride has no reading.
    struct Frame: Equatable {
        let time: Double
        let readout: Readout?
    }

    // MARK: GPMF

    /// The GPS rows in one GPMF payload, scaled to real units, in the order
    /// latitude, longitude, altitude, 2D speed, 3D speed. GPMF is a tree of
    /// big-endian key-length-value entries; a stream carries its SCAL divisors
    /// beside its GPS5 (older cameras) or GPS9 (HERO11 and later) readings.
    static func gps(_ payload: Data) -> [[Double]] {
        let bytes = [UInt8](payload)
        var rows: [[Double]] = []
        func integer(_ at: Int, _ size: Int, signed: Bool) -> Double {
            var value: UInt64 = 0
            for index in 0..<size {value = value << 8 | UInt64(bytes[at + index])}
            guard signed, size < 8, value >> (size * 8 - 1) & 1 == 1 else {return Double(value)}
            return Double(Int64(bitPattern: value | ~((1 << UInt64(size * 8)) - 1)))
        }
        func numbers(_ type: UInt8, _ size: Int, _ count: Int, _ start: Int) -> [Double] {
            let kinds: [UInt8: (Int, Bool)] = [UInt8(ascii: "l"): (4, true), UInt8(ascii: "L"): (4, false), UInt8(ascii: "s"): (2, true),
                                               UInt8(ascii: "S"): (2, false), UInt8(ascii: "b"): (1, true), UInt8(ascii: "B"): (1, false)]
            guard let kind = kinds[type] else {return []}
            let (width, signed) = kind
            let perEntry = max(1, size / width)
            return (0..<(count * perEntry)).map {integer(start + $0 * width, width, signed: signed)}
        }
        func walk(_ from: Int, _ to: Int) {
            var scale: [Double] = [], fix = 3.0, offset = from
            while offset + 8 <= to {
                let key = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                let type = bytes[offset + 4], size = Int(bytes[offset + 5])
                let count = Int(bytes[offset + 6]) << 8 | Int(bytes[offset + 7])
                let start = offset + 8, end = start + size * count
                guard end <= to else {return}
                if type == 0 {walk(start, end)}
                else if key == "SCAL" {scale = numbers(type, size, count, start)}
                else if key == "GPSF" {fix = numbers(type, size, count, start).first ?? fix}
                else if key == "GPS5" && size >= 20 && fix >= 2 || key == "GPS9" && size >= 32 {
                    for entry in 0..<count {
                        // GPS9 carries each reading's own lock as its ninth field,
                        // an unsigned short after seven longs and the precision.
                        if key == "GPS9" && integer(start + entry * size + 30, 2, signed: false) < 2 {continue}
                        let row = (0..<5).map {field -> Double in
                            let divisor = scale.count > field ? scale[field] : (scale.first ?? 1)
                            return integer(start + entry * size + field * 4, 4, signed: true) / (divisor == 0 ? 1 : divisor)
                        }
                        // No position yet: the receiver had not locked on.
                        if row[0] != 0 || row[1] != 0 {rows.append(row)}
                    }
                }
                offset = start + (size * count + 3) / 4 * 4
            }
        }
        walk(0, bytes.count)
        return rows
    }

    /// Every GPS reading in the project's videos, in timeline seconds, with
    /// distance added up along the way. Videos without GoPro data add nothing.
    static func load(_ project: LocalProject) async -> [Sample] {
        var samples: [Sample] = []
        for piece in project.pieces {
            samples += await readings(AVURLAsset(url: LocalStore.file(piece.file, project: project.id)), offset: piece.start)
        }
        return withDistance(samples)
    }

    private static func readings(_ asset: AVAsset, offset: Double) async -> [Sample] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata) else {return []}
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            guard formats.contains(where: {CMFormatDescriptionGetMediaSubType($0) == 0x67706D64}) else {continue} // 'gpmd'
            guard let reader = try? AVAssetReader(asset: asset) else {return []}
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else {return []}
            reader.add(output)
            guard reader.startReading() else {return []}
            defer {reader.cancelReading()}
            var samples: [Sample] = []
            while let buffer = output.copyNextSampleBuffer() {
                if Task.isCancelled {return []}
                let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                let length = CMSampleBufferGetDuration(buffer).seconds
                guard start.isFinite, let block = CMSampleBufferGetDataBuffer(buffer) else {continue}
                var data = Data(count: CMBlockBufferGetDataLength(block))
                let copied = data.withUnsafeMutableBytes {CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)}
                guard copied == kCMBlockBufferNoErr else {continue}
                let rows = gps(data)
                let span = length.isFinite && length > 0 ? length : 1
                for (index, row) in rows.enumerated() {
                    samples.append(Sample(time: offset + start + span * Double(index) / Double(rows.count), speed: row[3], altitude: row[2]))
                }
            }
            return samples
        }
        return []
    }

    static func withDistance(_ samples: [Sample]) -> [Sample] {
        var result = samples.sorted {$0.time < $1.time}, total = 0.0
        for index in result.indices {
            if index > 0 {
                // A gap in the recording is not distance travelled.
                let gap = result[index].time - result[index - 1].time
                if gap > 0 && gap < 2 {total += max(0, result[index].speed) * gap}
            }
            result[index].distance = total
        }
        return result
    }

    /// The reading at a ride second, averaged over the second around it so the
    /// number does not flicker with GPS noise.
    static func readout(at time: Double, in samples: [Sample]) -> Readout? {
        guard !samples.isEmpty else {return nil}
        var low = 0, high = samples.count
        while low < high {let middle = (low + high) / 2; if samples[middle].time < time - 0.5 {low = middle + 1} else {high = middle}}
        var near: [Sample] = []
        var index = low
        while index < samples.count && samples[index].time <= time + 0.5 {near.append(samples[index]); index += 1}
        guard !near.isEmpty else {return nil}
        let speed = near.map(\.speed).reduce(0, +) / Double(near.count)
        let altitude = near.map(\.altitude).reduce(0, +) / Double(near.count)
        return Readout(speed: Int((max(0, speed) * 3.6).rounded()), altitude: Int(altitude.rounded()),
                       distance: ((near[near.count / 2].distance / 1000) * 10).rounded() / 10)
    }

    /// The overlay twice a second through the movie: each moment is traced
    /// back to the ride second it shows.
    static func frames(clips: [Clip], segments: [LocalEngine.Segment], speed: Double, length: Double, samples: [Sample]) -> [Frame] {
        guard !samples.isEmpty, !segments.isEmpty else {return []}
        return stride(from: 0.0, to: length, by: 0.5).map {moment in
            guard let index = segments.indices.last(where: {segments[$0].start <= moment + 0.0001}) else {return Frame(time: moment, readout: nil)}
            let ride = clips[index].footage(atScreen: moment - segments[index].start, speed: speed)
            return Frame(time: moment, readout: readout(at: ride, in: samples))
        }
    }

    // MARK: Drawing

    static let unit = NSLocalizedString("קמ״ש", comment: "Kilometres per hour")
    static func detail(_ readout: Readout) -> String {
        String(format: NSLocalizedString("גובה %1$@ מ׳ · %2$@ ק״מ", comment: "Height and distance on the overlay"),
               "\(readout.altitude)", String(format: "%.1f", readout.distance))
    }

    /// The panel drawn into the exported movie, as on a ride computer.
    static func panel(_ readout: Readout, width: CGFloat) -> CGImage? {
        let size = CGSize(width: width, height: (width * 0.42).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image {_ in
            UIColor(white: 0, alpha: 0.55).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height * 0.22).fill()
            let pad = size.height * 0.14
            let big = NSAttributedString(string: "\(readout.speed)", attributes: [
                .font: RK.uiFont(size.height * 0.48, 700).withSize(size.height * 0.48), .foregroundColor: UIColor(red: 0.78, green: 0.96, blue: 0.26, alpha: 1)])
            let small = NSAttributedString(string: unit, attributes: [.font: RK.uiFont(size.height * 0.17, 500).withSize(size.height * 0.17), .foregroundColor: UIColor(white: 1, alpha: 0.85)])
            let line = NSAttributedString(string: detail(readout), attributes: [.font: RK.uiFont(size.height * 0.15, 400).withSize(size.height * 0.15), .foregroundColor: UIColor(white: 1, alpha: 0.8)])
            big.draw(at: CGPoint(x: pad, y: pad * 0.6))
            small.draw(at: CGPoint(x: pad + big.size().width + pad * 0.4, y: pad * 0.6 + big.size().height * 0.55))
            line.draw(at: CGPoint(x: pad, y: size.height - pad - line.size().height))
        }
        return image.cgImage
    }

    /// Each distinct readout drawn once, placed low on the left of a frame of
    /// `render` size, ready to lay over the movie in its Core Image pass.
    static func panels(_ frames: [Frame], render: CGSize) -> [Readout: CIImage] {
        let width = (min(render.width, render.height) * 0.42).rounded()
        let margin = (min(render.width, render.height) * 0.05).rounded()
        var panels: [Readout: CIImage] = [:]
        for readout in Set(frames.compactMap(\.readout)) {
            guard let image = panel(readout, width: width) else {continue}
            // Core Image's origin is the bottom left: the panel sits low.
            panels[readout] = CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: margin, y: margin * 1.6))
        }
        return panels
    }
    /// The frame with the ride computer over it, when there is a reading then.
    static func composite(_ frame: CIImage, at time: Double, frames: [Frame], panels: [Readout: CIImage]) -> CIImage {
        guard time.isFinite, time >= 0 else {return frame}
        let index = Int(time / 0.5)
        guard index < frames.count, let readout = frames[index].readout, let panel = panels[readout] else {return frame}
        return panel.composited(over: frame)
    }
}

extension Clip {
    /// The source moment shown a given time into this clip's screen time:
    /// the inverse of `screenOffset`, slow motion included.
    func footage(atScreen offset: Double, speed: Double) -> Double {
        let shown = max(0, offset) * speed
        guard let slow = slowRange else {return min(end, start + shown)}
        let before = slow.start - start, slowed = (slow.end - slow.start) * pace
        if shown <= before {return start + shown}
        if shown <= before + slowed {return slow.start + (shown - before) / pace}
        return min(end, slow.end + shown - before - slowed)
    }
}
