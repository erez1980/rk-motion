import Foundation

/// What the scan found the footage to be. Each kind is a recipe over the
/// same per-second signals: what counts as a moment worth keeping, and
/// whether the source sound stays under the music.
enum ContentKind: String, Codable, CaseIterable, Identifiable {
    case action, party, trip, talk, family, general
    var id: String {rawValue}
    var title: String {
        switch self {
        case .action: return NSLocalizedString("רכיבה או ספורט אקשן", comment: "Content kind")
        case .party: return NSLocalizedString("מסיבה או אירוע עם ריקודים", comment: "Content kind")
        case .trip: return NSLocalizedString("טיול", comment: "Content kind")
        case .talk: return NSLocalizedString("דיבור, נאום או הרצאה", comment: "Content kind")
        case .family: return NSLocalizedString("ילדים ומשפחה", comment: "Content kind")
        case .general: return NSLocalizedString("סרטון כללי", comment: "Content kind")
        }
    }
    var symbol: String {
        switch self {
        case .action: return "bicycle"
        case .party: return "party.popper"
        case .trip: return "map"
        case .talk: return "person.wave.2"
        case .family: return "figure.2.and.child.holdinghands"
        case .general: return "film"
        }
    }
    /// What the edit will look for, told to the user before they see it.
    var plan: String {
        switch self {
        case .action: return NSLocalizedString("אחתוך את הקטעים עם הכי הרבה תנועה ורעש: מהירות, קפיצות וירידות.", comment: "Edit plan")
        case .party: return NSLocalizedString("אחתוך את קטעי הריקוד, השמחה והצחוק, ואשתיק את קול המקור כדי שהמוזיקה שלו לא תתנגש בשיר.", comment: "Edit plan")
        case .trip: return NSLocalizedString("אחתוך רגעים עם תנועה, אנשים בפריים וצחוק, ואשאיר את קול המקור מתחת למוזיקה.", comment: "Edit plan")
        case .talk: return NSLocalizedString("אחתוך את קטעי הדיבור ואת התגובות של הקהל, ואשאיר את קול המקור.", comment: "Edit plan")
        case .family: return NSLocalizedString("אחתוך את רגעי הצחוק והשמחה ואת הקטעים עם אנשים בפריים.", comment: "Edit plan")
        case .general: return NSLocalizedString("אחתוך את הקטעים החיים ביותר: תנועה, קולות ואנשים.", comment: "Edit plan")
        }
    }
    /// Only a party loses its source sound by default: its own music would
    /// clash with the song.
    var mutesOriginal: Bool {self == .party}
    /// How each signal weighs into a second's score. Action keeps the
    /// original ride formula exactly, so ride edits do not change.
    var weights: [Signals.Channel: Double] {
        switch self {
        case .action: return [.motion: 0.65, .loudness: 0.35]
        case .party: return [.motion: 0.4, .music: 0.2, .cheer: 0.2, .people: 0.2]
        case .trip: return [.motion: 0.35, .people: 0.25, .cheer: 0.2, .loudness: 0.2]
        case .talk: return [.speech: 0.5, .cheer: 0.25, .loudness: 0.15, .people: 0.1]
        case .family: return [.cheer: 0.35, .people: 0.3, .motion: 0.2, .loudness: 0.15]
        case .general: return [.motion: 0.45, .loudness: 0.25, .cheer: 0.15, .people: 0.15]
        }
    }
}

/// Per-second measurements from one scan. Motion and loudness are raw;
/// music, speech and cheer are 0...1 confidences; people is a head count.
/// A channel the device could not measure stays empty.
struct Signals: Codable, Equatable {
    enum Channel: String, Codable {case motion, loudness, music, speech, cheer, people}
    var motion: [Double] = []
    var loudness: [Double] = []
    var music: [Double] = []
    var speech: [Double] = []
    /// Laughter, cheering and applause.
    var cheer: [Double] = []
    var people: [Double] = []
    /// Scene labels and the share of sampled frames that showed them.
    var scenes: [String: Double] = [:]
    /// Where across the frame people stand each second, 0 left … 1 right,
    /// or -1 when nobody is seen; nil for scans made before it was measured.
    var focus: [Double]? = nil

    func values(_ channel: Channel) -> [Double] {
        switch channel {
        case .motion: return LocalEngine.normalized(motion)
        case .loudness: return LocalEngine.normalized(loudness)
        case .music: return music
        case .speech: return speech
        case .cheer: return cheer
        case .people: return people.map {min(1, $0 / 4)}
        }
    }
    /// Several videos' signals as one timeline of `pieces` laid end to end,
    /// second by second. A channel only some videos measured reads as zero
    /// in the others; a channel none measured stays empty. Scene shares are
    /// weighed by how long each video runs.
    static func joined(_ pieces: [(signals: Signals, start: Double, duration: Double)]) -> Signals {
        guard pieces.count > 1 else {return pieces.first?.signals ?? Signals()}
        let total = pieces.reduce(0) {$0 + $1.duration}
        let count = max(1, Int(ceil(total)))
        // Each second takes its middle moment's video and that video's own second.
        let place = (0..<count).map {second -> (piece: Int, local: Int) in
            let at = min(Double(second) + 0.5, max(0, total - 0.0001))
            let piece = pieces.lastIndex {$0.start <= at} ?? 0
            return (piece, max(0, Int(at - pieces[piece].start)))
        }
        func join(_ channel: KeyPath<Signals, [Double]>) -> [Double] {
            guard pieces.contains(where: {!$0.signals[keyPath: channel].isEmpty}) else {return []}
            return place.map {
                let values = pieces[$0.piece].signals[keyPath: channel]
                return values.isEmpty ? 0 : values[min(values.count - 1, $0.local)]
            }
        }
        var scenes: [String: Double] = [:]
        for piece in pieces where total > 0 {
            for (label, share) in piece.signals.scenes {scenes[label, default: 0] += share * piece.duration / total}
        }
        let focus: [Double]? = pieces.contains(where: {!($0.signals.focus ?? []).isEmpty}) ? place.map {
            let values = pieces[$0.piece].signals.focus ?? []
            return values.isEmpty ? -1 : values[min(values.count - 1, $0.local)]
        } : nil
        return Signals(motion: join(\.motion), loudness: join(\.loudness), music: join(\.music), speech: join(\.speech),
                       cheer: join(\.cheer), people: join(\.people), scenes: scenes, focus: focus)
    }
    /// Each second's score for `kind`. Channels that were not measured drop
    /// out and the rest are scaled back up, so a missing one never sinks
    /// every score below the threshold.
    func scores(for kind: ContentKind) -> [Double] {
        let count = motion.count
        var total = [Double](repeating: 0, count: count), weight = 0.0
        for (channel, share) in kind.weights {
            let values = values(channel)
            guard values.count == count, count > 0 else {continue}
            weight += share
            for index in 0..<count {total[index] += share * (values[index].isFinite ? values[index] : 0)}
        }
        guard weight > 0 else {return total}
        return total.map {$0 / weight}
    }
}

/// What the scan concluded, with the numbers the user is shown as reasons.
struct ContentReading: Codable, Equatable {
    var detected: ContentKind
    /// The kind the edit follows: the detected one until the user picks another.
    var kind: ContentKind
    var musicShare: Double
    var speechShare: Double
    var cheerShare: Double
    /// Usual number of people in frame, from the sampled frames.
    var people: Int
    /// 0 still … 1 very fast, from the average frame change.
    var motion: Double
    var outdoors: Double

    static let actionScenes: Set<String> = ["bicycle", "motorcycle", "ski", "skiing", "snowboard", "snowboarding", "surfing", "surfboard", "skateboard", "skateboarding", "mountain_bike", "dirt_road", "trail", "motocross"]
    static let outdoorScenes: Set<String> = ["outdoor", "sky", "mountain", "forest", "beach", "sea", "ocean", "water", "road", "trail", "snow", "landscape", "tree", "grass", "desert", "hill", "field", "lake", "river", "cliff"]
    static let partyScenes: Set<String> = ["party", "celebration", "concert", "nightclub", "dance", "dancing", "wedding", "stage", "crowd", "disco", "festival", "balloon", "cake"]
    static let childScenes: Set<String> = ["child", "baby", "toddler", "kid", "children", "infant", "playground", "toy"]

    /// Weighs the summary numbers into the most likely kind; a weak match
    /// on every kind reads as general footage.
    static func read(_ signals: Signals) -> ContentReading {
        func share(_ values: [Double], above: Double) -> Double {
            values.isEmpty ? 0 : Double(values.filter {$0 > above}.count) / Double(values.count)
        }
        func scenes(_ names: Set<String>) -> Double {min(1, signals.scenes.filter {names.contains($0.key)}.map {$0.value}.max() ?? 0)}
        let music = share(signals.music, above: 0.5), speech = share(signals.speech, above: 0.5), cheer = share(signals.cheer, above: 0.3)
        let counts = signals.people.sorted()
        let people = counts.isEmpty ? 0 : Int(counts[counts.count / 2].rounded())
        let meanMotion = signals.motion.isEmpty ? 0 : signals.motion.reduce(0, +) / Double(signals.motion.count)
        // A still camera changes about 1% a frame; a bike ride well over 6%.
        let motion = min(1, max(0, (meanMotion - 0.01) / 0.07))
        let outdoors = scenes(outdoorScenes), crowd = min(1, Double(people) / 3)
        let likelihood: [ContentKind: Double] = [
            .action: 0.5 * motion + 0.3 * scenes(actionScenes) + 0.2 * outdoors - 0.3 * speech - 0.2 * music,
            .party: 0.4 * music + 0.25 * crowd + 0.2 * min(1, cheer * 3) + 0.15 * scenes(partyScenes),
            .trip: 0.45 * outdoors + 0.2 * (1 - abs(motion - 0.4)) + 0.15 * min(1, Double(people) / 2) - 0.2 * music,
            // A still, quiet camera counts as talk only when someone talks.
            .talk: 0.6 * speech + 0.4 * min(1, speech * 3) * (1 - motion) * (1 - music) - 0.2 * outdoors,
            .family: 0.5 * scenes(childScenes) + 0.3 * min(1, cheer * 3) + 0.2 * min(1, Double(people) / 2),
        ]
        let best = likelihood.max {$0.value < $1.value || ($0.value == $1.value && $0.key.rawValue > $1.key.rawValue)}
        let kind = (best?.value ?? 0) >= 0.35 ? best!.key : .general
        return ContentReading(detected: kind, kind: kind, musicShare: music, speechShare: speech, cheerShare: cheer,
                              people: people, motion: motion, outdoors: outdoors)
    }

    /// The reasons shown under "what I found", most telling first.
    var facts: [String] {
        var facts: [String] = []
        let percent = {(value: Double) in Int((value * 100).rounded())}
        if musicShare >= 0.2 {facts.append(String(format: NSLocalizedString("מוזיקה ב־%d%% מהזמן", comment: "Detected fact"), percent(musicShare)))}
        if speechShare >= 0.2 {facts.append(String(format: NSLocalizedString("דיבור ב־%d%% מהזמן", comment: "Detected fact"), percent(speechShare)))}
        if cheerShare >= 0.05 {facts.append(NSLocalizedString("צחוק, קריאות או מחיאות כפיים", comment: "Detected fact"))}
        if people == 1 {facts.append(NSLocalizedString("בדרך כלל אדם אחד בפריים", comment: "Detected fact"))}
        else if people > 1 {facts.append(String(format: NSLocalizedString("בדרך כלל %d אנשים בפריים", comment: "Detected fact"), people))}
        if motion >= 0.6 {facts.append(NSLocalizedString("הרבה תנועה ומהירות", comment: "Detected fact"))}
        else if motion <= 0.15 {facts.append(NSLocalizedString("מצלמה כמעט יציבה", comment: "Detected fact"))}
        if outdoors >= 0.4 {facts.append(NSLocalizedString("צולם בחוץ", comment: "Detected fact"))}
        return facts
    }
}
