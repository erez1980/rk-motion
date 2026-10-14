import Foundation

struct Clip: Codable, Identifiable, Equatable {
    var uid = UUID().uuidString
    var start: Double
    var end: Double
    var score: Double?
    var selected: Bool? = true
    var manual: Bool?
    var duration: Double {end - start}
    var id: String {uid}
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
struct LocalProject: Codable, Identifiable {
    var id = UUID().uuidString
    var created = Date()
    var name: String
    var source: String
    var duration: Double = 0
    var scores: [Double] = []
    var scoresFile: String?
    var analyzed = false
    var wholeVideo = false
    var edit = Edit(clips: [])
    var music: [LocalMusic] = []
    var exports: [LocalExport] = []
}
struct AppError: LocalizedError {
    let message: String
    // Engine failures are thrown as Hebrew source text; the catalog turns them
    // into the reader's language, and an assembled message passes through.
    var errorDescription: String? {NSLocalizedString(message, comment: "Engine failure shown to the rider")}
}
