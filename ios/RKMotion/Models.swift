import Foundation

struct Clip: Codable, Identifiable, Equatable {
    var uid: String
    var start: Double
    var end: Double
    var score: Double?
    var selected: Bool?
    var manual: Bool?
    var duration: Double { end - start }
    var id: String { uid }
    enum CodingKeys: String, CodingKey { case uid, start, end, score, selected, manual, duration }
    init(start: Double, end: Double, score: Double? = nil) {
        self.uid = UUID().uuidString; self.start = start; self.end = end
        self.score = score; self.selected = true
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decodeIfPresent(String.self, forKey: .uid) ?? UUID().uuidString
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
        manual = try c.decodeIfPresent(Bool.self, forKey: .manual)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        try c.encode(duration, forKey: .duration); try c.encodeIfPresent(score, forKey: .score)
        try c.encodeIfPresent(selected, forKey: .selected); try c.encodeIfPresent(manual, forKey: .manual)
    }
}

enum Setting: Codable, Equatable {
    case text(String), flag(Bool), number(Double)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .flag(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {case .text(let v): try c.encode(v); case .flag(let v): try c.encode(v); case .number(let v): try c.encode(v)}
    }
    var string: String { switch self {case .text(let v): return v; case .number(let v): return String(v); case .flag(let v): return String(v)} }
    var bool: Bool { if case .flag(let v) = self { return v }; return string == "true" }
}

struct Edit: Codable, Equatable {
    var clips: [Clip]
    var settings: [String: Setting] = ["quality": .text("1080"), "aspect": .text("16:9"), "speed": .text("1"),
        "transition": .text("cut"), "transitionDuration": .text("0.5"), "musicStart": .text("0"),
        "musicVolume": .text("0.65"), "muteOriginal": .flag(false)]
}
struct Report: Decodable { var job_id: String; var duration: Double; var clips: [Clip]; var whole: Bool? }
struct Status: Decodable { var state: String; var percent: Double?; var message: String?; var report: Report?; var download: String? }
struct Export: Decodable, Identifiable { var version: Int; var download: String; var duration: Double; var quality: String; var aspect: String; var id: Int {version} }
struct Music: Decodable { var name: String; var duration: Double }
struct Session: Decodable { var edit: Edit?; var revision: Int; var exports: [Export]; var music: [Music] }
struct Project: Decodable, Identifiable { var job_id: String; var created: Double?; var ready: Bool; var id: String {job_id} }
struct ProjectList: Decodable { var projects: [Project] }
struct Prepared: Decodable { var job_id: String }
struct UploadStart: Decodable { var upload_id: String; var offset: Int64 }
struct UploadStatus: Decodable { var offset: Int64; var complete: Bool }
struct Revision: Decodable { var revision: Int }
struct Accepted: Decodable { var status_url: String }
struct Capabilities: Decodable { var version: String; var encoder: String }
struct Paired: Decodable { var token: String }
struct OK: Decodable { var ok: Bool }

struct AppError: LocalizedError { let message: String; var errorDescription: String? {message} }

extension Encodable {
    func jsonObject() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) }
}
