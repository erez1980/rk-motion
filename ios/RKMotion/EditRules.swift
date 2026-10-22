import Foundation

/// The rider's own rules over the suggested clips: a ceiling on how long
/// one clip runs, and every video of a project kept in the movie.
enum ClipRules {
    /// The longest a suggested clip may run, in source seconds; nil leaves them as found.
    static func maxLength(_ settings: [String: Setting]) -> Double? {
        guard let value = settings["maxClip"].flatMap({Double($0.string)}), value.isFinite, value >= 1 else {return nil}
        return value
    }
    /// Whether every video of a project gives the movie at least one clip. On unless turned off.
    static func everyVideo(_ settings: [String: Setting]) -> Bool {settings["everyVideo"]?.bool != false}
    /// How long a clip is when one has to be made for a video the scan found nothing in.
    static let coverLength = 4.0

    /// The mean score of the seconds a stretch covers, or nil without scores.
    static func score(_ scores: [Double], from start: Double, to end: Double) -> Double? {
        guard !scores.isEmpty, end > start else {return nil}
        let first = max(0, min(scores.count - 1, Int(start))), last = max(first, min(scores.count - 1, Int(ceil(end)) - 1))
        let slice = scores[first...last].map {$0.isFinite ? $0 : 0}
        return slice.reduce(0, +) / Double(slice.count)
    }
    /// The strongest stretch `length` seconds long between `start` and `end`, tried every half second.
    static func best(_ scores: [Double], length: Double, from start: Double, to end: Double) -> (start: Double, end: Double) {
        guard end - start > length + 0.0001 else {return (start, end)}
        var found = (start: start, end: start + length), top = -Double.infinity
        for at in stride(from: start, through: end - length, by: 0.5) {
            let value = score(scores, from: at, to: at + length) ?? 0
            if value > top + 1e-9 {top = value; found = (at, at + length)}
        }
        return found
    }
    /// Cuts every clip longer than `limit` down to its strongest moments:
    /// one `limit`-long piece out of each stretch twice that long, so a long
    /// activity still gives several short, separate shots. Manual clips stay
    /// as the rider made them.
    static func capped(_ clips: [Clip], limit: Double?, scores: [Double]) -> [Clip] {
        guard let limit else {return clips}
        return clips.flatMap {clip -> [Clip] in
            guard clip.manual != true, clip.duration > limit + 0.0001 else {return [clip]}
            let chunks = max(1, Int((clip.duration / (limit * 2)).rounded(.down)))
            let size = clip.duration / Double(chunks)
            return (0..<chunks).map {index in
                let from = clip.start + Double(index) * size
                let window = best(scores, length: limit, from: from, to: min(clip.end, from + size))
                var piece = clip
                piece.start = window.start; piece.end = window.end
                piece.score = score(scores, from: window.start, to: window.end) ?? clip.score
                if index > 0 {piece.uid = UUID().uuidString}
                return piece
            }
        }
    }
    /// Adds a clip, the video's strongest few seconds, for each video that
    /// has none, so a project of several videos shows something of every one.
    static func covered(_ clips: [Clip], parts: [ProjectPart], scores: [Double], limit: Double?) -> [Clip] {
        guard parts.count > 1 else {return clips}
        var result = clips
        for part in parts where !clips.contains(where: {inside($0, part)}) && part.duration > 0.2 {
            let length = min(part.duration, limit ?? coverLength, coverLength)
            let window = best(scores, length: length, from: part.start, to: part.end)
            result.append(Clip(start: window.start, end: window.end, score: score(scores, from: window.start, to: window.end) ?? 0))
        }
        // Suggestions play in the order they were filmed; the rider's own clips stay at the end.
        let suggested = result.filter {$0.manual != true}.sorted {$0.start < $1.start}
        return suggested + result.filter {$0.manual == true}
    }
    static func inside(_ clip: Clip, _ part: ProjectPart) -> Bool {
        clip.start >= part.start - 0.0001 && clip.end <= part.end + 0.0001
    }
    /// The suggested clips with the rider's rules applied: long ones cut
    /// down, and a clip made for every video left without one.
    static func apply(_ clips: [Clip], parts: [ProjectPart], scores: [Double], settings: [String: Setting]) -> [Clip] {
        let limit = maxLength(settings)
        let short = capped(clips, limit: limit, scores: scores)
        return Edit.capped(everyVideo(settings) ? covered(short, parts: parts, scores: scores, limit: limit) : short)
    }
    /// Which video each clip comes from, for choosing at least one from each.
    static func groups(_ clips: [Clip], parts: [ProjectPart]) -> [Int]? {
        guard parts.count > 1 else {return nil}
        return clips.map {clip in parts.firstIndex {inside(clip, $0)} ?? -1}
    }
}

/// Where the movie slows down: nowhere but the clips the rider marked, on
/// the strongest moment of the whole movie, or on the strongest moment of
/// every clip.
enum SlowMotion {
    static let modes = ["off", "peak", "each"]
    static let rates = ["2", "3", "4"]
    static let lengths = ["1.5", "3"]
    /// The edit's mode; edits made before there was a choice used one switch for the peak.
    static func mode(_ settings: [String: Setting]) -> String {
        if let mode = settings["slowMode"]?.string, modes.contains(mode) {return mode}
        return settings["slowPeak"]?.bool == true ? "peak" : "off"
    }
    static func rate(_ settings: [String: Setting]) -> Double {
        settings["slowRate"].flatMap {Double($0.string)}.flatMap {$0.isFinite && $0 >= 1 && $0 <= 8 ? $0 : nil} ?? Clip.slowFactor
    }
    static func length(_ settings: [String: Setting]) -> Double {
        settings["slowLength"].flatMap {Double($0.string)}.flatMap {$0.isFinite && $0 >= 0.5 && $0 <= 10 ? $0 : nil} ?? Clip.slowSpan
    }
    /// The clips as the movie plays them: the rider's marks kept, the mode's
    /// own marks added on clips without one, all at the edit's rate and length.
    static func shaped(_ clips: [Clip], scores: [Double], settings: [String: Setting]) -> [Clip] {
        let rate = rate(settings), length = length(settings)
        var result = clips.map {clip -> Clip in
            var clip = clip
            clip.slowRate = rate; clip.slowLength = length
            return clip
        }
        guard !scores.isEmpty else {return result}
        switch mode(settings) {
        case "peak":
            if let peak = Highlights.peak(result, scores: scores), result[peak.clip].slowAt == nil {
                result[peak.clip].slowAt = peak.time - length / 2
            }
        case "each":
            for index in result.indices where result[index].slowAt == nil {
                if let peak = Highlights.peak([result[index]], scores: scores) {result[index].slowAt = peak.time - length / 2}
            }
        default: break
        }
        return result
    }
}
