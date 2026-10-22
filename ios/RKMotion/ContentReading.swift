import Foundation

/// What the scan found the footage to be. Each kind is a recipe over the
/// same per-second signals: what counts as a moment worth keeping, and
/// whether the source sound stays under the music.
enum ContentKind: String, Codable, CaseIterable, Identifiable {
    case action, party, trip, talk, family, pets, sports, scenery, food, general
    var id: String {rawValue}
    var title: String {
        switch self {
        case .action: return NSLocalizedString("רכיבה או ספורט אקשן", comment: "Content kind")
        case .party: return NSLocalizedString("מסיבה או אירוע עם ריקודים", comment: "Content kind")
        case .trip: return NSLocalizedString("טיול", comment: "Content kind")
        case .talk: return NSLocalizedString("דיבור, נאום או הרצאה", comment: "Content kind")
        case .family: return NSLocalizedString("ילדים ומשפחה", comment: "Content kind")
        case .pets: return NSLocalizedString("חיות מחמד", comment: "Content kind")
        case .sports: return NSLocalizedString("ספורט וכושר", comment: "Content kind")
        case .scenery: return NSLocalizedString("נוף וטבע", comment: "Content kind")
        case .food: return NSLocalizedString("אוכל ומסעדות", comment: "Content kind")
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
        case .pets: return "pawprint"
        case .sports: return "figure.run"
        case .scenery: return "mountain.2"
        case .food: return "fork.knife"
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
        case .pets: return NSLocalizedString("אחתוך את הרגעים שהחיה בפריים וזזה, ואת הצחוקים סביבה.", comment: "Edit plan")
        case .sports: return NSLocalizedString("אחתוך את רגעי השיא: תנועה מהירה, קריאות עידוד ומחיאות כפיים.", comment: "Edit plan")
        case .scenery: return NSLocalizedString("אחתוך את הפריימים היפים ביותר, עם תנועת מצלמה רגועה.", comment: "Edit plan")
        case .food: return NSLocalizedString("אחתוך את הצילומים היפים של האוכל ואת הרגעים סביב השולחן.", comment: "Edit plan")
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
        case .family: return [.cheer: 0.3, .people: 0.25, .motion: 0.2, .loudness: 0.1, .beauty: 0.15]
        case .pets: return [.animals: 0.45, .motion: 0.25, .cheer: 0.15, .beauty: 0.15]
        case .sports: return [.motion: 0.5, .cheer: 0.25, .loudness: 0.15, .people: 0.1]
        case .scenery: return [.beauty: 0.6, .motion: 0.2, .loudness: 0.2]
        case .food: return [.beauty: 0.5, .people: 0.2, .cheer: 0.15, .speech: 0.15]
        case .general: return [.motion: 0.4, .loudness: 0.2, .cheer: 0.15, .people: 0.1, .beauty: 0.15]
        }
    }
}

/// Per-second measurements from one scan. Motion and loudness are raw;
/// music, speech and cheer are 0...1 confidences; people is a head count.
/// A channel the device could not measure stays empty.
struct Signals: Codable, Equatable {
    enum Channel: String, Codable {case motion, loudness, music, speech, cheer, people, animals, beauty}
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
    /// Animals in frame each second (a count), and how good the frame looks,
    /// 0 … 1, by the on-device aesthetics model; nil when not measured.
    var animals: [Double]? = nil
    var beauty: [Double]? = nil

    func values(_ channel: Channel) -> [Double] {
        switch channel {
        case .motion: return LocalEngine.normalized(motion)
        case .loudness: return LocalEngine.normalized(loudness)
        case .music: return music
        case .speech: return speech
        case .cheer: return cheer
        case .people: return people.map {min(1, $0 / 4)}
        case .animals: return (animals ?? []).map {min(1, $0 / 2)}
        case .beauty: return beauty ?? []
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
        func optional(_ channel: KeyPath<Signals, [Double]?>) -> [Double]? {
            guard pieces.contains(where: {!($0.signals[keyPath: channel] ?? []).isEmpty}) else {return nil}
            return place.map {
                let values = pieces[$0.piece].signals[keyPath: channel] ?? []
                return values.isEmpty ? 0 : values[min(values.count - 1, $0.local)]
            }
        }
        return Signals(motion: join(\.motion), loudness: join(\.loudness), music: join(\.music), speech: join(\.speech),
                       cheer: join(\.cheer), people: join(\.people), scenes: scenes, focus: focus,
                       animals: optional(\.animals), beauty: optional(\.beauty))
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
    /// Share of the sampled frames with an animal in them; nil for older scans.
    var animals: Double?
    /// How sure the reading is, 0 … 1, and the next most likely kind, offered as a one-tap switch.
    var confidence: Double?
    var runnerUp: ContentKind?
    /// Set when the on-device language model settled a close call.
    var byModel: Bool?

    static let actionScenes: Set<String> = ["bicycle", "bike", "cycling", "motorcycle", "motorbike", "ski", "skiing", "snowboard", "snowboarding", "surfing", "surfboard", "skateboard", "skateboarding", "mountain", "dirt", "trail", "motocross", "atv", "kayak", "kayaking", "canoe", "rafting", "wakeboarding", "jet", "paragliding", "parachute", "skydiving", "climbing", "car", "vehicle", "racing", "kart", "horse", "riding", "sled", "boat", "sailboat"]
    static let outdoorScenes: Set<String> = ["outdoor", "sky", "mountain", "forest", "beach", "sea", "ocean", "water", "road", "trail", "snow", "landscape", "tree", "grass", "desert", "hill", "field", "lake", "river", "cliff", "sunset", "sunrise", "cloud", "waterfall", "park", "garden", "canyon", "coast", "shore", "island", "valley", "street", "city", "cityscape", "bridge"]
    static let partyScenes: Set<String> = ["party", "celebration", "concert", "nightclub", "dance", "dancing", "wedding", "stage", "crowd", "disco", "festival", "balloon", "cake", "fireworks", "confetti", "bride", "groom", "birthday", "bar", "performance", "dj", "lights"]
    static let childScenes: Set<String> = ["child", "baby", "toddler", "kid", "children", "infant", "playground", "toy", "teddy", "stroller", "swing", "slide"]
    static let petScenes: Set<String> = ["dog", "cat", "puppy", "kitten", "pet", "animal", "canine", "feline", "bird", "parrot", "hamster", "rabbit", "horse", "pony", "fish", "aquarium", "leash"]
    static let sportScenes: Set<String> = ["sport", "sports", "soccer", "football", "basketball", "tennis", "volleyball", "baseball", "golf", "swimming", "pool", "gym", "fitness", "running", "jogging", "stadium", "ball", "yoga", "boxing", "martial", "rugby", "hockey", "athlete", "track", "court", "marathon", "workout", "weightlifting", "padel"]
    static let sceneryScenes: Set<String> = ["landscape", "mountain", "sunset", "sunrise", "sky", "cloud", "waterfall", "lake", "ocean", "sea", "beach", "forest", "canyon", "valley", "desert", "aurora", "glacier", "coast", "horizon", "nature", "panorama", "cityscape", "skyline", "volcano", "meadow"]
    static let foodScenes: Set<String> = ["food", "meal", "dish", "dessert", "pizza", "burger", "hamburger", "sushi", "cake", "coffee", "drink", "restaurant", "kitchen", "cooking", "bread", "salad", "fruit", "baked", "pasta", "steak", "barbecue", "grill", "breakfast", "dinner", "lunch", "wine", "cocktail", "plate", "table", "chocolate", "ice", "cream", "vegetable", "soup"]

    /// The share of frames that showed any label in `names`. A label counts
    /// when one of its words is in the set, so "sunset_sunrise" is a sunset.
    static func share(_ scenes: [String: Double], _ names: Set<String>) -> Double {
        let found = scenes.filter {label, _ in
            label.lowercased().split(whereSeparator: {$0 == "_" || $0 == " " || $0 == "-"}).contains {names.contains(String($0))}
        }
        return min(1, found.values.max() ?? 0)
    }
    /// How likely each kind is from the summary numbers, roughly 0 … 1.
    static func likelihoods(_ signals: Signals) -> (likelihood: [ContentKind: Double], reading: ContentReading) {
        func share(_ values: [Double], above: Double) -> Double {
            values.isEmpty ? 0 : Double(values.filter {$0 > above}.count) / Double(values.count)
        }
        func scenes(_ names: Set<String>) -> Double {Self.share(signals.scenes, names)}
        let music = share(signals.music, above: 0.5), speech = share(signals.speech, above: 0.5), cheer = share(signals.cheer, above: 0.3)
        let counts = signals.people.sorted()
        let people = counts.isEmpty ? 0 : Int(counts[counts.count / 2].rounded())
        let meanMotion = signals.motion.isEmpty ? 0 : signals.motion.reduce(0, +) / Double(signals.motion.count)
        // A still camera changes about 1% a frame; a bike ride well over 6%.
        let motion = min(1, max(0, (meanMotion - 0.01) / 0.07))
        let outdoors = scenes(outdoorScenes), crowd = min(1, Double(people) / 3)
        let animals = max(share(signals.animals ?? [], above: 0.5), scenes(petScenes))
        let beautyValues = signals.beauty ?? []
        let beauty = beautyValues.isEmpty ? 0 : beautyValues.reduce(0, +) / Double(beautyValues.count)
        let likelihood: [ContentKind: Double] = [
            .action: 0.5 * motion + 0.3 * scenes(actionScenes) + 0.2 * outdoors - 0.3 * speech - 0.2 * music,
            .party: 0.4 * music + 0.25 * crowd + 0.2 * min(1, cheer * 3) + 0.15 * scenes(partyScenes),
            .trip: 0.45 * outdoors + 0.2 * (1 - abs(motion - 0.4)) + 0.15 * min(1, Double(people) / 2) - 0.2 * music,
            // A still, quiet camera counts as talk only when someone talks.
            .talk: 0.6 * speech + 0.4 * min(1, speech * 3) * (1 - motion) * (1 - music) - 0.2 * outdoors,
            .family: 0.5 * scenes(childScenes) + 0.3 * min(1, cheer * 3) + 0.2 * min(1, Double(people) / 2),
            .pets: 0.75 * animals + 0.15 * min(1, cheer * 3) + 0.1 * motion,
            .sports: 0.55 * scenes(sportScenes) + 0.25 * motion + 0.2 * min(1, cheer * 3) - 0.2 * music,
            // Wide places filmed calmly, with nobody much in frame.
            .scenery: 0.55 * scenes(sceneryScenes) + 0.2 * beauty + 0.15 * (1 - motion) + 0.1 * (people == 0 ? 1 : 0) - 0.3 * speech,
            .food: 0.75 * scenes(foodScenes) + 0.15 * beauty + 0.1 * (1 - motion),
        ]
        let reading = ContentReading(detected: .general, kind: .general, musicShare: music, speechShare: speech, cheerShare: cheer,
                                     people: people, motion: motion, outdoors: outdoors, animals: animals)
        return (likelihood, reading)
    }
    /// The bar a kind must clear; under it the footage reads as general.
    static let threshold = 0.3

    /// Weighs the summary numbers into the most likely kind; a weak match
    /// on every kind reads as general footage.
    static func read(_ signals: Signals) -> ContentReading {
        let found = likelihoods(signals)
        let likelihood = found.likelihood
        var reading = found.reading
        let ranked = likelihood.sorted {$0.value > $1.value || ($0.value == $1.value && $0.key.rawValue < $1.key.rawValue)}
        let best = ranked.first, second = ranked.dropFirst().first
        let kind = (best?.value ?? 0) >= threshold ? best!.key : .general
        reading.detected = kind; reading.kind = kind
        reading.confidence = min(1, max(0, best?.value ?? 0))
        let alternative = kind == .general ? best : second
        if let alternative, alternative.value >= threshold * 0.6, alternative.key != kind {reading.runnerUp = alternative.key}
        return reading
    }
    /// Whether the reading is a close call worth a second opinion.
    var uncertain: Bool {
        (confidence ?? 1) < 0.45 || kind == .general
    }

    /// The reasons shown under "what I found", most telling first.
    var facts: [String] {
        var facts: [String] = []
        let percent = {(value: Double) in Int((value * 100).rounded())}
        if byModel == true {facts.append(NSLocalizedString("Apple Intelligence עזרה לזהות", comment: "Detected fact"))}
        if musicShare >= 0.2 {facts.append(String(format: NSLocalizedString("מוזיקה ב־%d%% מהזמן", comment: "Detected fact"), percent(musicShare)))}
        if speechShare >= 0.2 {facts.append(String(format: NSLocalizedString("דיבור ב־%d%% מהזמן", comment: "Detected fact"), percent(speechShare)))}
        if cheerShare >= 0.05 {facts.append(NSLocalizedString("צחוק, קריאות או מחיאות כפיים", comment: "Detected fact"))}
        if people == 1 {facts.append(NSLocalizedString("בדרך כלל אדם אחד בפריים", comment: "Detected fact"))}
        else if people > 1 {facts.append(String(format: NSLocalizedString("בדרך כלל %d אנשים בפריים", comment: "Detected fact"), people))}
        if (animals ?? 0) >= 0.3 {facts.append(NSLocalizedString("חיה בפריים", comment: "Detected fact"))}
        if motion >= 0.6 {facts.append(NSLocalizedString("הרבה תנועה ומהירות", comment: "Detected fact"))}
        else if motion <= 0.15 {facts.append(NSLocalizedString("מצלמה כמעט יציבה", comment: "Detected fact"))}
        if outdoors >= 0.4 {facts.append(NSLocalizedString("צולם בחוץ", comment: "Detected fact"))}
        return facts
    }
}

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A second opinion on a close call from the on-device language model,
/// given only what the scan measured: labels and numbers, never pictures.
enum ModelReading {
    /// The scene labels seen most, for the model's prompt.
    static func topScenes(_ signals: Signals, limit: Int = 15) -> [String] {
        signals.scenes.filter {$0.value >= 0.08}.sorted {$0.value > $1.value || ($0.value == $1.value && $0.key < $1.key)}
            .prefix(limit).map {"\($0.key.replacingOccurrences(of: "_", with: " ")) (\(Int(($0.value * 100).rounded()))%)"}
    }
    static func prompt(_ reading: ContentReading, signals: Signals) -> String {
        var lines = ["Things seen in the video's frames, with the share of frames: " + (topScenes(signals).joined(separator: ", ").nilIfEmpty ?? "nothing clear") + "."]
        lines.append("Music is heard \(Int((reading.musicShare * 100).rounded()))% of the time, speech \(Int((reading.speechShare * 100).rounded()))%.")
        if reading.cheerShare >= 0.05 {lines.append("People laugh, cheer or clap.")}
        lines.append("Usually \(reading.people) people are in frame.")
        if (reading.animals ?? 0) >= 0.2 {lines.append("An animal is often in frame.")}
        lines.append(reading.motion >= 0.6 ? "The camera moves fast." : reading.motion <= 0.15 ? "The camera is almost still." : "The camera moves a little.")
        return lines.joined(separator: " ")
    }
    /// The kind a model answer names, read from its first matching word.
    static func parse(_ text: String) -> ContentKind? {
        let words = text.lowercased().split(whereSeparator: {!$0.isLetter}).map(String.init)
        return words.lazy.compactMap {ContentKind(rawValue: $0)}.first
    }
    /// The reading, settled by the model when it was a close call and the
    /// iPhone has Apple Intelligence ready; otherwise as it was.
    static func refine(_ reading: ContentReading, signals: Signals) async -> ContentReading {
        guard reading.uncertain else {return reading}
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {return reading}
            let names = ContentKind.allCases.map(\.rawValue).joined(separator: ", ")
            let session = LanguageModelSession(instructions: """
                You sort short personal phone videos into one kind. The kinds are: \(names). \
                action is riding or action sports; party is a party, wedding or concert; trip is travel; \
                talk is a speech or lecture; family is kids and family; pets is animals; sports is ball games and fitness; \
                scenery is landscapes and nature; food is meals and restaurants; general is anything else. \
                Answer with the one kind word only.
                """)
            do {
                let answer = try await session.respond(to: prompt(reading, signals: signals))
                guard let kind = parse(answer.content), kind != reading.kind else {return reading}
                var settled = reading
                settled.runnerUp = reading.kind == .general ? settled.runnerUp : reading.kind
                settled.detected = kind; settled.kind = kind; settled.byModel = true
                return settled
            } catch {return reading}
        }
        #endif
        return reading
    }
}

private extension String {
    var nilIfEmpty: String? {isEmpty ? nil : self}
}
