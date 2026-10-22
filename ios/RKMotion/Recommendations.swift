import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Songs to look for on YouTube, from what the scan found the footage to be.
/// A few searches are always offered for each kind and pace; on an iPhone
/// with Apple Intelligence the on-device model also names real songs.
enum SongIdeas {
    struct Idea: Identifiable, Equatable {
        /// What the button shows.
        let title: String
        /// What is searched on YouTube.
        let query: String
        /// Named by the on-device model, not one of the fixed searches.
        var named = false
        var id: String {query}
    }

    /// How lively the footage is, 0 calm … 1 wild: its motion, with laughter and cheering on top.
    static func energy(_ reading: ContentReading) -> Double {
        min(1, max(0, reading.motion * 0.75 + min(1, reading.cheerShare * 3) * 0.25))
    }
    /// The tempo whose beats suit the footage's pace, in beats a minute.
    static func tempo(for reading: ContentReading) -> ClosedRange<Int> {
        switch reading.kind {
        case .talk: return 70...95
        case .party: return 115...128
        case .scenery, .food: return 75...100
        default:
            let energy = energy(reading)
            return energy >= 0.6 ? 125...150 : energy >= 0.3 ? 100...125 : 80...105
        }
    }

    /// Searches that suit the kind and its pace, liveliest first for lively footage.
    static func ideas(for reading: ContentReading) -> [Idea] {
        let lively = energy(reading) >= 0.5
        func idea(_ title: String, _ query: String) -> Idea {Idea(title: title, query: query)}
        switch reading.kind {
        case .action:
            let fast = [idea(NSLocalizedString("רוק אנרגטי", comment: "Song idea"), "energetic rock action edit music"),
                        idea(NSLocalizedString("פונק לדריפט", comment: "Song idea"), "phonk drift music"),
                        idea(NSLocalizedString("דראם אנד בייס", comment: "Song idea"), "drum and bass action sports")]
            let steady = [idea(NSLocalizedString("אינדי רוק קצבי", comment: "Song idea"), "upbeat indie rock road music"),
                          idea(NSLocalizedString("אפי ואנרגטי", comment: "Song idea"), "epic motivational music sports edit")]
            return lively ? fast + steady : steady + fast
        case .party:
            return [idea(NSLocalizedString("להיטי מסיבות", comment: "Song idea"), "dance party hits"),
                    idea(NSLocalizedString("שירי חתונה לריקודים", comment: "Song idea"), "wedding dance floor songs"),
                    idea(NSLocalizedString("להיטים ישראליים שמחים", comment: "Song idea"), "Israeli party hits"),
                    idea(NSLocalizedString("האוס לקיץ", comment: "Song idea"), "summer house music party")]
        case .trip:
            let bright = [idea(NSLocalizedString("מוזיקה לוולוג טיולים", comment: "Song idea"), "upbeat travel vlog music"),
                          idea(NSLocalizedString("אינדי פולק לדרך", comment: "Song idea"), "indie folk road trip songs")]
            let calm = [idea(NSLocalizedString("אקוסטי רגוע", comment: "Song idea"), "acoustic chill travel music"),
                        idea(NSLocalizedString("שירי טיולים ישראליים", comment: "Song idea"), "Israeli road trip songs")]
            return lively ? bright + calm : calm + bright
        case .talk:
            return [idea(NSLocalizedString("פסנתר שקט ברקע", comment: "Song idea"), "soft piano background music for speech"),
                    idea(NSLocalizedString("לו־פיי רגוע", comment: "Song idea"), "lofi chill background music no vocals"),
                    idea(NSLocalizedString("מעורר השראה", comment: "Song idea"), "inspirational background music no vocals")]
        case .family:
            return [idea(NSLocalizedString("שמח עם יוקלילי", comment: "Song idea"), "happy ukulele family music"),
                    idea(NSLocalizedString("שירים מרגשים למשפחה", comment: "Song idea"), "feel good family songs"),
                    idea(NSLocalizedString("שירי ילדים שמחים", comment: "Song idea"), "happy Israeli kids songs"),
                    idea(NSLocalizedString("שריקה ומחיאות כפיים", comment: "Song idea"), "happy whistle clap background music")]
        case .pets:
            return [idea(NSLocalizedString("שמח ומשעשע", comment: "Song idea"), "funny happy pet video music"),
                    idea(NSLocalizedString("שמח עם יוקלילי", comment: "Song idea"), "happy ukulele family music"),
                    idea(NSLocalizedString("פופ שמח", comment: "Song idea"), "upbeat feel good pop songs")]
        case .sports:
            return [idea(NSLocalizedString("אפי ואנרגטי", comment: "Song idea"), "epic motivational music sports edit"),
                    idea(NSLocalizedString("היפ הופ לאימון", comment: "Song idea"), "workout hip hop music"),
                    idea(NSLocalizedString("רוק אנרגטי", comment: "Song idea"), "energetic rock action edit music")]
        case .scenery:
            return [idea(NSLocalizedString("קולנועי", comment: "Song idea"), "cinematic background music"),
                    idea(NSLocalizedString("אמביינט לנופים", comment: "Song idea"), "ambient nature cinematic music drone"),
                    idea(NSLocalizedString("אקוסטי רגוע", comment: "Song idea"), "acoustic chill travel music")]
        case .food:
            return [idea(NSLocalizedString("ג'אז קליל", comment: "Song idea"), "light jazz cafe music"),
                    idea(NSLocalizedString("לו־פיי רגוע", comment: "Song idea"), "lofi chill beats"),
                    idea(NSLocalizedString("בוסה נובה", comment: "Song idea"), "bossa nova restaurant music")]
        case .general:
            let up = [idea(NSLocalizedString("פופ שמח", comment: "Song idea"), "upbeat feel good pop songs"),
                      idea(NSLocalizedString("להיטי הקיץ", comment: "Song idea"), "summer hits")]
            let soft = [idea(NSLocalizedString("קולנועי", comment: "Song idea"), "cinematic background music"),
                        idea(NSLocalizedString("לו־פיי רגוע", comment: "Song idea"), "lofi chill beats")]
            return lively ? up + soft : soft + up
        }
    }

    /// Songs the on-device model names for the footage, as YouTube searches.
    /// Empty when the iPhone has no Apple Intelligence model ready, or it
    /// declines; the fixed searches still stand.
    static func named(for reading: ContentReading, seconds: Double?) async -> [Idea] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {return []}
            let session = LanguageModelSession(instructions: """
                You pick background music for short personal videos shared on Instagram and WhatsApp. \
                Suggest real, well-known songs that exist on YouTube. Answer only with the list, \
                one song per line, written as: Artist - Song title. No numbering and no other text.
                """)
            do {
                let answer = try await session.respond(to: prompt(for: reading, seconds: seconds))
                return parse(answer.content)
            } catch {return []}
        }
        #endif
        return []
    }

    /// What the model is told about the footage, in plain words.
    static func prompt(for reading: ContentReading, seconds: Double?) -> String {
        let kinds: [ContentKind: String] = [.action: "a ride or action sport", .party: "a party or event with dancing", .trip: "a trip",
                                            .talk: "a talk, speech or lecture", .family: "kids and family moments", .pets: "pets and animals",
                                            .sports: "sports or a workout", .scenery: "landscapes and nature", .food: "food and a meal", .general: "everyday moments"]
        var facts = ["The video is \(kinds[reading.kind] ?? "everyday moments")."]
        let energy = energy(reading)
        facts.append(energy >= 0.6 ? "It is fast and wild." : energy >= 0.3 ? "It has a lively, steady pace." : "It is calm.")
        if reading.cheerShare >= 0.05 {facts.append("People laugh and cheer.")}
        if reading.outdoors >= 0.4 {facts.append("It was filmed outdoors.")}
        if reading.people > 1 {facts.append("Usually \(reading.people) people are in frame.")}
        if reading.kind == .talk {facts.append("The music sits quietly under speech, so it must have no vocals.")}
        let tempo = tempo(for: reading)
        facts.append("The cuts land on the beat, so songs around \(tempo.lowerBound) to \(tempo.upperBound) BPM suit it.")
        if let seconds, seconds > 0 {facts.append("The finished movie lasts about \(Int(seconds.rounded())) seconds.")}
        return facts.joined(separator: " ") + " Suggest 5 songs."
    }

    /// "Artist - Song" lines, tolerating numbering, bullets and quotes.
    static func parse(_ text: String, limit: Int = 5) -> [Idea] {
        var seen = Set<String>(), ideas: [Idea] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            // A leading "1." or "2)" or bullet goes; a name that starts with a number stays.
            var line = raw.replacingOccurrences(of: #"^\s*(\d{1,2}[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: "")
                .replacingOccurrences(of: " – ", with: " - ").replacingOccurrences(of: " — ", with: " - ")
                .trimmingCharacters(in: .whitespaces)
            let parts = line.components(separatedBy: " - ").map {$0.trimmingCharacters(in: .whitespaces)}
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty, line.count <= 120 else {continue}
            let title = parts[0] + " – " + parts[1...].joined(separator: " - ")
            let query = parts[0] + " " + parts[1...].joined(separator: " ")
            guard seen.insert(query.lowercased()).inserted else {continue}
            ideas.append(Idea(title: title, query: query, named: true))
            if ideas.count == limit {break}
        }
        return ideas
    }
}

/// Picks each seam's transition from what happens on both sides of it, so a
/// movie mixes them the way an editor would: a dip to black where time or
/// place jumps, a zoom into a burst of speed, a flash on a cheer, a push
/// between two fast moments and a soft dissolve between calm ones.
enum SmartTransitions {
    static let name = "smart"

    /// One transition for each seam between consecutive clips, never "cut".
    static func styles(for clips: [Clip], signals: Signals?, kind: ContentKind?, pieces: [ProjectPart]) -> [String] {
        guard clips.count > 1 else {return []}
        let motion = signals.map {$0.values(.motion)} ?? []
        let cheer = signals?.cheer ?? []
        /// The mean of `values` over the seconds from `from` to `to`.
        func mean(_ values: [Double], _ from: Double, _ to: Double) -> Double? {
            guard !values.isEmpty else {return nil}
            let low = max(0, min(values.count - 1, Int(from))), high = max(low, min(values.count - 1, Int(ceil(to)) - 1))
            let slice = values[low...high].map {$0.isFinite ? $0 : 0}
            return slice.reduce(0, +) / Double(slice.count)
        }
        func piece(_ time: Double) -> Int {pieces.lastIndex {$0.start <= time + 0.0001} ?? 0}
        var styles: [String] = []
        for index in 0..<(clips.count - 1) {
            let before = clips[index], after = clips[index + 1]
            // Two seconds either side of the seam, inside each clip.
            let out = mean(motion, max(before.start, before.end - 2), before.end)
            let into = mean(motion, after.start, min(after.end, after.start + 2))
            let cheering = mean(cheer, after.start, min(after.end, after.start + 2)) ?? 0
            let jump = piece(before.start) != piece(after.start) || after.start < before.start || after.start - before.end > 60
            var style: String
            if jump {
                style = "fade"
            } else if kind == .talk {
                style = "dissolve"
            } else if cheering >= 0.5 {
                style = "flash"
            } else if let out, let into {
                if into - out >= 0.3 {style = "zoom"}
                else if out >= 0.55 && into >= 0.55 {style = "slide"}
                else if out < 0.3 && into < 0.3 {style = "dissolve"}
                else {style = fallback(kind)}
            } else {
                style = fallback(kind)
            }
            // A flash or a push wears thin twice in a row.
            if let last = styles.last, last == style, ["flash", "slide", "zoom"].contains(style) {
                style = style == "flash" ? "zoom" : "dissolve"
            }
            styles.append(style)
        }
        return styles
    }
    private static func fallback(_ kind: ContentKind?) -> String {
        switch kind {
        case .action: return "slide"
        case .party: return "zoom"
        default: return "dissolve"
        }
    }
}
