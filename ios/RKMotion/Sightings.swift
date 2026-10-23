import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import Vision

/// What one looked-at frame showed: the scene labels Vision gave it, and
/// the faces in it, each with a compact print to tell people apart. Kept
/// with the scan so the footage can be searched and a person followed
/// without scanning again.
struct Sighting: Codable, Equatable {
    var time: Double
    var labels: [String: Double]
    var faces: [Face]?

    struct Face: Codable, Equatable {
        /// Where the face is, 0 … 1 across the frame, origin bottom left, as Vision gives it.
        var x: Double, y: Double, width: Double, height: Double
        /// The face's feature print, scaled to unit length and stored as signed bytes.
        var print: Data
        var vector: [Float] {print.map {Float(Int8(bitPattern: $0)) / 127}}
    }

    /// The labels kept for each frame: the likeliest dozen.
    static let labelLimit = 12, labelFloor: Float = 0.2
    /// Faces smaller than this share of the frame's width are too small to tell apart.
    static let faceFloor = 0.06, faceLimit = 3

    static func labels(_ results: [VNClassificationObservation]) -> [String: Double] {
        let kept = results.filter {$0.confidence >= labelFloor}.sorted {$0.confidence > $1.confidence}.prefix(labelLimit)
        return Dictionary(kept.map {($0.identifier, (Double($0.confidence) * 100).rounded() / 100)}) {first, _ in first}
    }
    /// A feature print as signed bytes of the unit-length vector.
    static func packed(_ values: [Float]) -> Data {
        let length = sqrt(values.reduce(0) {$0 + $1 * $1})
        guard length > 0 else {return Data(count: values.count)}
        return Data(values.map {value -> UInt8 in
            let scaled: Float = (value / length * 127).rounded()
            return UInt8(bitPattern: Int8(max(-127, min(127, scaled))))
        })
    }
    static func floats(_ observation: VNFeaturePrintObservation) -> [Float] {
        let data = observation.data
        switch observation.elementType {
        case .float: return data.withUnsafeBytes {Array($0.bindMemory(to: Float.self))}
        case .double: return data.withUnsafeBytes {$0.bindMemory(to: Double.self).map {Float($0)}}
        default: return []
        }
    }
    /// The faces in `image` big enough to recognise, largest first, each with its print.
    static func faces(in image: CGImage) -> [Face] {
        let detect = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image).perform([detect])) != nil else {return []}
        let boxes = (detect.results ?? []).map(\.boundingBox).filter {$0.width >= faceFloor}
            .sorted {$0.width * $0.height > $1.width * $1.height}.prefix(faceLimit)
        return boxes.compactMap {box in
            guard let crop = image.cropping(to: pixels(box, in: CGSize(width: image.width, height: image.height), margin: 0.2)) else {return nil}
            let request = VNGenerateImageFeaturePrintRequest()
            request.imageCropAndScaleOption = .scaleFill
            guard (try? VNImageRequestHandler(cgImage: crop).perform([request])) != nil,
                  let observation = request.results?.first else {return nil}
            let values = floats(observation)
            guard !values.isEmpty else {return nil}
            return Face(x: Double(box.minX), y: Double(box.minY), width: Double(box.width), height: Double(box.height), print: packed(values))
        }
    }
    /// A Vision box (origin bottom left, 0 … 1) as pixels of an image `size`
    /// big (origin top left), grown by `margin` of its size on each side.
    static func pixels(_ box: CGRect, in size: CGSize, margin: CGFloat) -> CGRect {
        let grown = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGRect(x: grown.minX * size.width, y: (1 - grown.maxY) * size.height,
                      width: grown.width * size.width, height: grown.height * size.height).integral
    }
}

/// Finding moments by what is in them: "the dog", "the beach", in Hebrew
/// or English, matched against the labels Vision gave the looked-at frames.
enum FrameSearch {
    /// How long a found moment runs, centred on the frame that matched.
    static let momentLength = 4.0
    static let momentLimit = 8

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: {!$0.isLetter && $0 != "'"}).map(String.init)
    }
    /// Every label word in `vocabulary`, as `share` splits labels.
    static func labelWords(_ label: String) -> [String] {
        label.lowercased().split(whereSeparator: {$0 == "_" || $0 == " " || $0 == "-"}).map(String.init)
    }
    /// The label words a query asks for, from the Hebrew list (with a joined
    /// "the"/"and"/"in" taken off) or as English words themselves. Two-word
    /// Hebrew names are tried before single words.
    static func terms(for query: String) -> Set<String> {
        let all = words(query)
        var found = Set<String>()
        for (first, second) in zip(all, all.dropFirst()) {
            if let meant = hebrew[first + " " + second] ?? hebrew[strip(first) + " " + second] {found.formUnion(meant)}
        }
        for word in all where !fillers.contains(word) {
            if let meant = hebrew[word] {found.formUnion(meant); continue}
            let bare = strip(word)
            if bare != word, !fillers.contains(bare), let meant = hebrew[bare] {found.formUnion(meant); continue}
            if word.unicodeScalars.allSatisfy({$0.isASCII}) {found.insert(word.hasSuffix("s") && word.count > 3 ? String(word.dropLast()) : word)}
        }
        return found
    }
    /// A Hebrew word without the one or two letters joined to its front, when what is left is a known word.
    private static func strip(_ word: String) -> String {
        var rest = Substring(word)
        for _ in 0..<2 {
            guard let first = rest.first, prefixes.contains(first), rest.count > 2 else {break}
            rest = rest.dropFirst()
            if hebrew[String(rest)] != nil {return String(rest)}
        }
        return word
    }
    /// How strongly a frame shows any of `terms`: its best matching label's confidence.
    static func strength(_ sighting: Sighting, terms: Set<String>) -> Double {
        sighting.labels.filter {label, _ in labelWords(label).contains {terms.contains($0)}}.values.max() ?? 0
    }
    /// The moments that show what was searched for, strongest first, each
    /// `momentLength` long around its frame and inside one video. Moments
    /// that overlap become one.
    static func moments(_ sightings: [Sighting], terms: Set<String>, parts: [ProjectPart]) -> [Clip] {
        guard !terms.isEmpty, !parts.isEmpty else {return []}
        let hits = sightings.map {($0.time, strength($0, terms: terms))}.filter {$0.1 > 0}
        var found: [Clip] = []
        for (time, value) in hits.sorted(by: {$0.0 < $1.0}) {
            let part = parts.last {$0.start <= time + 0.0001} ?? parts[0]
            let length = min(momentLength, part.duration)
            let start = min(max(part.start, time - length / 2), part.end - length)
            let end = start + length
            if let last = found.last, last.start >= part.start - 0.0001, last.end >= start - 0.0001 {
                found[found.count - 1].end = max(last.end, end)
                found[found.count - 1].score = max(last.score ?? 0, value)
            } else {
                found.append(Clip(start: start, end: end, score: value))
            }
        }
        let kept = Set(found.indices.sorted {(found[$0].score ?? 0) > (found[$1].score ?? 0)}.prefix(momentLimit))
        return found.indices.filter {kept.contains($0)}.map {index in
            var clip = found[index]; clip.manual = true; return clip
        }
    }
    /// The labels the footage showed, most seen first, for the model to choose from.
    static func vocabulary(_ sightings: [Sighting], limit: Int = 120) -> [String] {
        var seen: [String: Int] = [:]
        for sighting in sightings {for label in sighting.labels.keys {seen[label, default: 0] += 1}}
        return seen.sorted {$0.value > $1.value || ($0.value == $1.value && $0.key < $1.key)}.prefix(limit).map(\.key)
    }
}

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks the on-device model which of the labels the footage showed a free
/// search means, for words the Hebrew list does not know.
enum ModelSearch {
    static func prompt(_ query: String, vocabulary: [String]) -> String {
        "Someone searches their video for: \"\(query)\". These labels were seen in its frames: " +
            vocabulary.map {$0.replacingOccurrences(of: "_", with: " ")}.joined(separator: ", ") +
            ". Which of these labels show what they search for? Answer with the matching labels only, separated by commas, or none."
    }
    /// The label words of `vocabulary` an answer names.
    static func parse(_ answer: String, vocabulary: [String]) -> Set<String> {
        let text = answer.lowercased()
        var found = Set<String>()
        for label in vocabulary where text.contains(label.lowercased().replacingOccurrences(of: "_", with: " ")) {
            found.formUnion(FrameSearch.labelWords(label))
        }
        return found
    }
    static func terms(_ query: String, vocabulary: [String]) async -> Set<String> {
        guard !vocabulary.isEmpty else {return []}
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {return []}
            let session = LanguageModelSession(instructions: "You match a search in any language to labels that describe video frames.")
            guard let answer = try? await session.respond(to: prompt(query, vocabulary: vocabulary)) else {return []}
            return parse(answer.content, vocabulary: vocabulary)
        }
        #endif
        return []
    }
}

/// The people in the footage, told apart by their face prints, so one of
/// them can be made the movie's star.
enum FaceGroups {
    /// How alike two face prints must be to count as the same person.
    static let likeness: Float = 0.8
    /// A person must be seen this many times to be offered.
    static let minimumSightings = 2, shown = 6

    struct Group: Equatable, Identifiable {
        /// "sighting:face" of the person's first face: the same footage always gives the same key.
        var key: String
        var members: [(sighting: Int, face: Int)]
        /// The member with the biggest face, for the picture.
        var best: (sighting: Int, face: Int)
        var id: String {key}
        static func == (a: Group, b: Group) -> Bool {a.key == b.key && a.members.map {[$0.sighting, $0.face]} == b.members.map {[$0.sighting, $0.face]}}
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else {return 0}
        var dot: Float = 0, left: Float = 0, right: Float = 0
        for index in a.indices {dot += a[index] * b[index]; left += a[index] * a[index]; right += b[index] * b[index]}
        return left > 0 && right > 0 ? dot / (left.squareRoot() * right.squareRoot()) : 0
    }
    /// Groups the faces in the order they were seen: each joins the person
    /// it is most like, when alike enough, or starts a new one. People seen
    /// often come first.
    static func groups(_ sightings: [Sighting]) -> [Group] {
        var people: [(key: String, sum: [Float], members: [(sighting: Int, face: Int)])] = []
        for (s, sighting) in sightings.enumerated() {
            for (f, face) in (sighting.faces ?? []).enumerated() {
                let vector = face.vector
                guard !vector.isEmpty else {continue}
                let match = people.indices.map {($0, similarity(people[$0].sum, vector))}.max {$0.1 < $1.1}
                if let match, match.1 >= likeness {
                    people[match.0].members.append((s, f))
                    for index in vector.indices where index < people[match.0].sum.count {people[match.0].sum[index] += vector[index]}
                } else {
                    people.append(("\(s):\(f)", vector, [(s, f)]))
                }
            }
        }
        func area(_ member: (sighting: Int, face: Int)) -> Double {
            let face = sightings[member.sighting].faces![member.face]
            return face.width * face.height
        }
        return people.filter {$0.members.count >= minimumSightings}
            .sorted {$0.members.count > $1.members.count || ($0.members.count == $1.members.count && $0.key < $1.key)}
            .prefix(shown)
            .map {Group(key: $0.key, members: $0.members, best: $0.members.max {area($0) < area($1)}!)}
    }
    /// The group with `key`, among all people seen, not only those offered.
    static func group(_ key: String, in sightings: [Sighting]) -> Group? {
        groups(sightings).first {$0.key == key}
    }
    /// Each of `count` seconds: whether the person is in frame, from the
    /// nearest looked-at frame.
    static func presence(_ group: Group, sightings: [Sighting], count: Int) -> [Bool] {
        guard !sightings.isEmpty, count > 0 else {return []}
        let seen = Set(group.members.map(\.sighting))
        return (0..<count).map {second in
            let at = Double(second) + 0.5
            let nearest = sightings.indices.min {abs(sightings[$0].time - at) < abs(sightings[$1].time - at)}!
            return seen.contains(nearest)
        }
    }
    /// The star's face, cut from its frame of the footage.
    static func picture(_ file: URL, at seconds: Double, face: Sighting.Face) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image else {return nil}
        let box = CGRect(x: face.x, y: face.y, width: face.width, height: face.height)
        guard let crop = frame.cropping(to: Sighting.pixels(box, in: CGSize(width: frame.width, height: frame.height), margin: 0.35)) else {return nil}
        return UIImage(cgImage: crop)
    }
}
