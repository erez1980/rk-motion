import Foundation

struct Clip: Codable, Identifiable, Equatable {
    var uid = UUID().uuidString
    var start: Double
    var end: Double
    var score: Double?
    var selected: Bool? = true
    var manual: Bool?
    /// Where slow motion starts, in source seconds; nil plays the clip at one pace.
    var slowAt: Double?
    var duration: Double {end - start}
    var id: String {uid}
}
extension Clip {
    /// How long slow motion lasts in the source, and how much it slows it.
    static let slowSpan = 1.5, slowFactor = 2.0
    /// The source seconds played slowed, kept inside the clip; nil when
    /// none are marked or the clip is too short to slow a part of it.
    var slowRange: (start: Double, end: Double)? {
        guard let slowAt, slowAt.isFinite, duration >= Self.slowSpan + 0.5 else {return nil}
        let from = min(max(start, slowAt), end - Self.slowSpan)
        return (from, from + Self.slowSpan)
    }
    /// How long the clip is on screen at `speed`, slow motion included.
    func shown(_ speed: Double) -> Double {
        (duration + (slowRange == nil ? 0 : Self.slowSpan * (Self.slowFactor - 1))) / speed
    }
    /// How far into the clip, on screen, a source moment plays.
    func screenOffset(of time: Double, speed: Double) -> Double {
        let into = min(max(time, start), end) - start
        guard let slow = slowRange else {return into / speed}
        let from = slow.start - start, to = slow.end - start
        if into <= from {return into / speed}
        if into <= to {return (from + (into - from) * Self.slowFactor) / speed}
        return (from + (to - from) * Self.slowFactor + into - to) / speed
    }
}
enum Setting: Codable, Equatable {
    case text(String), flag(Bool), number(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) {self = .flag(v)}
        else if let v = try? c.decode(String.self) {self = .text(v)}
        else {self = .number(try c.decode(Double.self))}
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {case .text(let v): try c.encode(v); case .flag(let v): try c.encode(v); case .number(let v): try c.encode(v)}
    }
    var string: String {switch self {case .text(let v): return v; case .number(let v): return String(v); case .flag(let v): return String(v)}}
    var bool: Bool {if case .flag(let v) = self {return v}; return string == "true"}
}
struct Edit: Codable, Equatable {
    var clips: [Clip]
    var settings: [String: Setting] = ["quality": .text("1080"), "aspect": .text("source"), "speed": .text("1"),
        "transition": .text("cut"), "transitionDuration": .text("0.5"), "musicStart": .text("0"),
        "musicVolume": .text("0.65"), "muteOriginal": .flag(false), "useMusic": .flag(true)]
}
extension Edit {
    /// The most clips one movie can hold. The editor, the activity
    /// suggestions and the engine all use this one number.
    static let clipLimit = 500
    /// The movie length a new edit aims at, in seconds: short enough for a Reel or a status.
    static let defaultLength = "45"
    /// A long ride can suggest more clips than one movie holds. All stay
    /// listed; only the strongest of the chosen ones stay chosen, so the
    /// default edit exports.
    static func capped(_ clips: [Clip]) -> [Clip] {
        let chosen = clips.indices.filter {clips[$0].selected != false}
        guard chosen.count > clipLimit else {return clips}
        let kept = Set(chosen.sorted {(clips[$0].score ?? 0, -$0) > (clips[$1].score ?? 0, -$1)}.prefix(clipLimit))
        var result = clips
        for index in result.indices {result[index].selected = kept.contains(index)}
        return result
    }
    /// Where in a song the movie starts playing it. Each song keeps its own
    /// point; an older project's single start still applies to its first song.
    func musicStart(for song: String, first: Bool) -> Double {
        let own = settings["musicStart:" + song].flatMap {Double($0.string)}
        let value = own ?? (first ? Double(settings["musicStart"]?.string ?? "0") ?? 0 : 0)
        return value.isFinite ? max(0, value) : 0
    }
    mutating func setMusicStart(_ seconds: Double, for song: String) {
        settings["musicStart:" + song] = .text(String(format: "%.2f", max(0, seconds)))
    }
    /// The opening title over the first seconds of the movie, trimmed; empty
    /// when the rider left it blank.
    var openingTitle: (title: String, subtitle: String) {
        func line(_ key: String) -> String {
            String((settings[key]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(Edit.titleLimit))
        }
        return (line("titleText"), line("subtitleText"))
    }
    static let titleLimit = 60
}
/// One-tap clip choices, the same ones the web app's clip panel offers.
enum ClipPicker {
    /// Selects the strongest clips until the finished movie runs `seconds`,
    /// allowing a fifth over rather than stopping short. The order is kept.
    /// The length is measured on the real timeline, so speed and the overlap
    /// of every transition count.
    static func autoPick(_ clips: [Clip], seconds: Double, speed: Double = 1, transition: Double = 0) -> [Clip] {
        let usable = clips.indices.filter {clips[$0].duration.isFinite && clips[$0].duration > 0}
        let ranked = usable.sorted {(clips[$0].score ?? 1) > (clips[$1].score ?? 1)}
        func length(_ picked: Set<Int>) -> Double {
            LocalEngine.timeline(clips: picked.sorted().map {clips[$0]}, speed: speed, transition: transition).last?.end ?? 0
        }
        var chosen = Set<Int>(), total = 0.0
        for index in ranked {
            if total >= seconds {break}
            let trial = length(chosen.union([index]))
            if trial <= seconds * 1.2 {chosen.insert(index); total = trial}
        }
        if chosen.isEmpty, let best = ranked.first {chosen.insert(best)}
        return clips.indices.map {index in var clip = clips[index]; clip.selected = chosen.contains(index); return clip}
    }
    /// A new order, never the same one: a shuffle that changes nothing reads as broken.
    static func shuffled<G: RandomNumberGenerator>(_ clips: [Clip], using generator: inout G) -> [Clip] {
        guard clips.count > 1 else {return clips}
        var result = clips
        repeat {result.shuffle(using: &generator)} while result == clips
        return result
    }
}
struct LocalExport: Codable, Identifiable {
    var id = UUID().uuidString
    var file: String
    var created = Date()
    var duration: Double
}
struct LocalMusic: Codable, Identifiable {
    var id = UUID().uuidString
    var file: String
    var name: String
    var duration: Double
}
/// One video of a project made from several. The videos play one after
/// another on the project's own timeline, so `start` is where this one
/// begins on it, in seconds.
struct ProjectPart: Codable, Equatable {
    var file: String
    var start: Double
    var duration: Double
    var end: Double {start + duration}
    /// The videos laid end to end in the order given.
    static func laid(_ files: [String], durations: [Double]) -> [ProjectPart] {
        var cursor = 0.0
        return zip(files, durations).map {file, duration in
            defer {cursor += duration}
            return ProjectPart(file: file, start: cursor, duration: duration)
        }
    }
    /// Cuts every clip that runs from one video into the next at the seam,
    /// so each clip comes from a single video. A piece under a second is
    /// dropped unless it is the whole clip.
    static func fit(_ clips: [Clip], into parts: [ProjectPart], minimum: Double = 1) -> [Clip] {
        guard parts.count > 1 else {return clips}
        // Splitting adds clips, so the cap on chosen clips applies again.
        return Edit.capped(clips.flatMap {clip -> [Clip] in
            let pieces = parts.compactMap {part -> Clip? in
                let start = max(clip.start, part.start), end = min(clip.end, part.end)
                guard end > start else {return nil}
                var piece = clip; piece.start = start; piece.end = end
                return piece
            }
            guard pieces.count > 1 else {return pieces.isEmpty ? [clip] : pieces}
            let kept = pieces.filter {$0.duration >= minimum}
            let chosen = kept.isEmpty ? [pieces.max {$0.duration < $1.duration}!] : kept
            return chosen.enumerated().map {index, piece in
                var piece = piece
                if index > 0 {piece.uid = UUID().uuidString}
                return piece
            }
        })
    }
}
struct LocalProject: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date()
    var name: String
    /// The project's video, or the first of its videos.
    var source: String
    /// Set when the project joins several videos, in the order they play.
    var parts: [ProjectPart]?
    var duration: Double = 0
    var scores: [Double] = []
    var scoresFile: String?
    var analyzed = false
    var wholeVideo = false
    /// What the last scan found the video to be; nil before one, or when
    /// the whole video was kept and nothing was scanned.
    var reading: ContentReading?
    var edit = Edit(clips: [])
    var music: [LocalMusic] = []
    var exports: [LocalExport] = []
}
extension LocalProject {
    /// Every video file of the project, in the order they play.
    var files: [String] {parts.map {$0.map(\.file)} ?? [source]}
    /// The videos on the project's timeline; one video spans all of it.
    var pieces: [ProjectPart] {parts ?? [ProjectPart(file: source, start: 0, duration: duration)]}
    var joinsVideos: Bool {(parts?.count ?? 0) > 1}
    /// The video a moment of the timeline belongs to.
    func part(at time: Double) -> ProjectPart {
        pieces.last {$0.start <= time + 0.0001} ?? pieces[0]
    }
    /// The one video a clip lies inside, or nil when it crosses a seam.
    func part(for clip: Clip) -> ProjectPart? {
        guard joinsVideos else {return pieces.first}
        return pieces.first {clip.start >= $0.start - 0.0001 && clip.end <= $0.end + 0.0001}
    }
    func fitted(_ clips: [Clip]) -> [Clip] {ProjectPart.fit(clips, into: pieces)}
    /// One clip for each whole video.
    var wholeClips: [Clip] {pieces.map {Clip(start: $0.start, end: $0.end)}}
}
struct AppError: LocalizedError {
    let message: String
    // Engine failures are thrown as Hebrew source text; the catalog turns them
    // into the reader's language, and an assembled message passes through.
    var errorDescription: String? {NSLocalizedString(message, comment: "Engine failure shown to the rider")}
}
