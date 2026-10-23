import Foundation

/// Product actions have a complete recipe. No prompt, song picker, face picker or
/// export-settings screen is needed to execute one of these recipes.
enum AutomaticStyle: String, Codable, CaseIterable, Identifiable {
    case personal, action, cinematic, family, natural
    var id: String {rawValue}
    var title: String {
        switch self {
        case .personal: return NSLocalizedString("צור לי סרט", comment: "One-tap automatic movie")
        case .action: return NSLocalizedString("אקשן אוטומטי", comment: "Automatic action recipe")
        case .cinematic: return NSLocalizedString("קולנועי אוטומטי", comment: "Automatic cinematic recipe")
        case .family: return NSLocalizedString("סיפור משפחתי", comment: "Automatic family recipe")
        case .natural: return NSLocalizedString("הצלילים של הרגע", comment: "Automatic original-sound recipe")
        }
    }
    var symbol: String {
        switch self {
        case .personal: return "sparkles"
        case .action: return "bolt.fill"
        case .cinematic: return "film"
        case .family: return "person.2.fill"
        case .natural: return "waveform"
        }
    }
    func settings(kind: ContentKind, taste: AutomaticTaste) -> [String: Setting] {
        let calm = self == .cinematic || self == .family || self == .natural || kind == .talk
        var settings: [String: Setting] = [
            "automatic": .flag(true), "wholeVideo": .flag(false), "speed": .text("1"),
            "targetLength": .text(self == .family ? "60" : "45"), "quality": .text("1080"),
            "aspect": .text("9:16"), "smartFrame": .flag(true), "automaticFrame": .flag(true),
            "transition": .text(calm ? "dissolve" : SmartTransitions.name), "transitionDuration": .text("0.35"),
            "hook": .flag(!calm), "slowMode": .text(calm ? "off" : "peak"),
            "speedRamp": .flag(!calm), "beatZoom": .flag(self == .action), "whoosh": .flag(false),
            "muteOriginal": .flag(kind.mutesOriginal && self != .natural), "originalVolume": .text("0.6"),
            "musicVolume": .text(self == .family || kind == .talk ? "0.22" : "0.38"),
            "useMusic": .flag(self != .natural), "look": .text(self == .natural ? "none" : "auto"),
            "telemetry": .flag(true), "beatSync": .flag(false), "preserveEvents": .flag(true)
        ]
        // Only a human-originated export teaches preferences. Automation never
        // learns from its own output, which would reinforce its initial defaults.
        if self == .personal, taste.observations > 0 {
            settings["beatZoom"] = .flag(taste.zoom > 0.6)
            settings["whoosh"] = .flag(taste.whoosh > 0.65)
            settings["aspect"] = .text(taste.portrait >= 0.5 ? "9:16" : "source")
            settings["musicVolume"] = .text(String(format: "%.2f", taste.musicVolume))
        }
        return settings
    }
}

struct AutomaticTaste: Codable, Equatable {
    var observations = 0
    var zoom = 0.0, whoosh = 0.0, portrait = 1.0, musicVolume = 0.38
    var choices: [String: Int] = [:]
    var preferredStyle: AutomaticStyle? {
        let ranked = choices.sorted {$0.value != $1.value ? $0.value > $1.value : $0.key < $1.key}
        return ranked.first.flatMap {AutomaticStyle(rawValue: $0.key)}
    }
    mutating func choose(_ style: AutomaticStyle) {
        guard style != .personal else {return}
        choices[style.rawValue] = min(10000, (choices[style.rawValue] ?? 0) + 1)
    }
    mutating func learn(_ edit: Edit) {
        guard edit.settings["automatic"]?.bool != true else {return}
        let weight = 1 / Double(min(20, observations + 1))
        func blend(_ old: Double, _ next: Double) -> Double {old + weight * (next - old)}
        zoom = blend(zoom, edit.settings["beatZoom"]?.bool == true ? 1 : 0)
        whoosh = blend(whoosh, edit.settings["whoosh"]?.bool == true ? 1 : 0)
        portrait = blend(portrait, edit.settings["aspect"]?.string == "9:16" ? 1 : 0)
        let volume = Double(edit.settings["musicVolume"]?.string ?? "0.38") ?? 0.38
        if volume.isFinite {musicVolume = blend(musicVolume, min(0.65, max(0.08, volume)))}
        observations = min(10000, observations + 1)
    }
}

/// Evidence is measured, not a model's invented description of a jump or emotion.
struct AutomaticEvent: Codable, Equatable, Identifiable {
    enum Reason: String, Codable {case motion, speech, reaction, scenery, people, animal, telemetry}
    var id: String
    var file: String
    var start: Double
    var peak: Double
    var end: Double
    var score: Double
    var reason: Reason
    var visualKind: String? = nil
    var duration: Double {end - start}
    var clip: Clip {Clip(uid: id, start: start, end: end, score: score)}
    var title: String {
        switch reason {
        case .motion: return NSLocalizedString("תנועה בולטת", comment: "Measured event reason")
        case .speech: return NSLocalizedString("קטע דיבור", comment: "Measured event reason")
        case .reaction: return NSLocalizedString("צחוק או עידוד", comment: "Measured event reason")
        case .scenery: return NSLocalizedString("פריים יפה", comment: "Measured event reason")
        case .people: return NSLocalizedString("אנשים בפריים", comment: "Measured event reason")
        case .animal: return NSLocalizedString("חיה בפריים", comment: "Measured event reason")
        case .telemetry: return NSLocalizedString("שינוי בנתוני הרכיבה", comment: "Measured event reason")
        }
    }
}

enum AutomaticDirector {
    static let eventLimit = 128
    static let analysisVersion = 1
    static func value(_ values: [Double], _ index: Int) -> Double {
        guard index >= 0, index < values.count, values[index].isFinite else {return 0}
        return max(0, min(1, values[index]))
    }
    /// Independent windows per source. Quiet visual moments are considered as
    /// well as activity peaks. No clip can accidentally cross a file boundary.
    static func events(project: LocalProject, signals: Signals, telemetry: [Telemetry.Sample] = []) -> [AutomaticEvent] {
        let count = signals.motion.count
        guard count > 0, project.duration.isFinite, project.duration > 0, project.duration <= 86400 else {return []}
        let motion = LocalEngine.normalized(signals.motion), base = signals.scores(for: project.reading?.kind ?? .general), poor = signals.poor
        var metrics = [Int: Double]()
        let finite = telemetry.filter {$0.time.isFinite && $0.speed.isFinite && $0.time >= 0 && $0.time < project.duration}
        for pair in zip(finite, finite.dropFirst()) where pair.1.time > pair.0.time {
            let delta = min(1, abs(pair.1.speed - pair.0.speed) / max(0.5, pair.1.time - pair.0.time) / 5)
            metrics[Int(pair.1.time)] = max(metrics[Int(pair.1.time)] ?? 0, delta)
        }
        var result: [AutomaticEvent] = []
        for part in project.pieces where part.duration.isFinite && part.duration > 0.2 && part.start.isFinite && part.start >= 0 && part.end.isFinite && part.end <= project.duration + 0.001 {
            let first = max(0, Int(part.start)), last = min(count - 1, Int(ceil(part.end)) - 1)
            guard first <= last else {continue}
            let ranked = (first...last).map {second -> (Int, Double, AutomaticEvent.Reason) in
                let channels: [(AutomaticEvent.Reason, Double)] = [
                    (.motion, value(motion, second) * 0.75), (.speech, value(signals.speech, second) * 0.8),
                    (.reaction, value(signals.cheer, second)), (.scenery, value(signals.beauty ?? [], second) * 0.75),
                    (.people, min(1, value(signals.people, second)) * 0.45),
                    (.animal, value(signals.animals ?? [], second) * 0.7), (.telemetry, metrics[second] ?? 0)
                ]
                let best = channels.max {$0.1 < $1.1}!
                let quality = second < poor.count && poor[second] ? 0.25 : 1.0
                return (second, max(value(base, second), best.1) * quality, best.0)
            }.sorted {$0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0}
            var windows: [AutomaticEvent] = []
            for (second, score, reason) in ranked {
                guard windows.count < 24, result.count + windows.count < eventLimit else {break}
                let peak = min(part.end - 0.01, max(part.start, Double(second) + 0.5))
                if windows.contains(where: {abs($0.peak - peak) < 6}) {continue}
                var start = max(part.start, peak - 2), end = min(part.end, peak + 3)
                // Keep short speech/reaction runs complete instead of selecting
                // only their loudest second. Extension is bounded, not recursive.
                let active = max(value(signals.speech, second), value(signals.cheer, second)) >= 0.5
                if active {
                    var before = second, after = second
                    while before > first && second - before < 6 && max(value(signals.speech, before - 1), value(signals.cheer, before - 1)) >= 0.45 {before -= 1}
                    while after < last && after - second < 8 && max(value(signals.speech, after + 1), value(signals.cheer, after + 1)) >= 0.45 {after += 1}
                    start = max(part.start, min(start, Double(before) - 0.3))
                    end = min(part.end, max(end, Double(after + 1) + 0.5))
                }
                // Never duplicate the same source seconds in neighbouring events.
                if windows.contains(where: {min(end, $0.end) - max(start, $0.start) > 0.1}) {continue}
                guard end > start else {continue}
                windows.append(AutomaticEvent(id: "event-\(part.file)-\(second)", file: part.file, start: start, peak: peak, end: end, score: score, reason: reason))
            }
            result += windows
        }
        return result.sorted {$0.start < $1.start}
    }
    /// Whole event selection: a duration target is a budget, not permission to
    /// cut a speech or discard the end of a short event. One complete event is
    /// retained even when it alone exceeds the budget.
    static func choose(_ events: [AutomaticEvent], seconds: Double, style: AutomaticStyle, locked: [Clip] = []) -> [Clip] {
        guard seconds.isFinite, seconds > 0 else {return []}
        let manual = locked.filter {$0.manual == true && $0.selected != false}
        var chosen = manual, used = manual.reduce(0) {$0 + $1.duration}
        func rank(_ e: AutomaticEvent) -> Double {
            let bonus: Double
            switch style {
            case .action: bonus = [.motion, .telemetry].contains(e.reason) ? 0.3 : 0
            case .cinematic: bonus = e.reason == .scenery ? 0.4 : 0
            case .family: bonus = [.reaction, .people, .speech, .animal].contains(e.reason) ? 0.35 : 0
            case .natural: bonus = [.reaction, .speech].contains(e.reason) ? 0.35 : 0
            case .personal: bonus = 0
            }
            return e.score + bonus
        }
        let ranked = events.sorted {rank($0) != rank($1) ? rank($0) > rank($1) : $0.start < $1.start}
        for event in ranked where chosen.count < Edit.clipLimit {
            guard !chosen.contains(where: {min($0.end, event.end) > max($0.start, event.start) + 0.01}) else {continue}
            if chosen.isEmpty || used + event.duration <= seconds + 1 {chosen.append(event.clip); used += event.duration}
        }
        return chosen.sorted {$0.start < $1.start}
    }
    struct Review: Codable, Equatable {
        var removedInvalid = 0
        var removedDuplicate = 0
        var restoredEnding = 0
        var selectedEvents = 0
    }
    /// A bounded, deterministic critic. It verifies timing/evidence; it does not
    /// claim a model's self-rating proves the movie is compelling.
    static func review(_ edit: inout Edit, project: LocalProject, events: [AutomaticEvent]) -> Review {
        var result = Review(), kept: [Clip] = []
        for var clip in edit.clips where clip.selected != false {
            guard clip.start.isFinite, clip.end.isFinite, clip.end > clip.start,
                  clip.start >= 0, clip.end <= project.duration + 0.001, project.part(for: clip) != nil else {result.removedInvalid += 1; continue}
            if kept.contains(where: {$0.uid == clip.uid || (abs($0.start - clip.start) < 0.05 && abs($0.end - clip.end) < 0.05)}) {result.removedDuplicate += 1; continue}
            if clip.manual != true, let event = events.first(where: {$0.id == clip.uid}), clip.end < event.end {
                clip.end = event.end; result.restoredEnding += 1
            }
            kept.append(clip)
        }
        edit.clips = Array(kept.prefix(Edit.clipLimit))
        result.selectedEvents = edit.clips.count
        return result
    }
    /// A smoothed path rather than a per-clip median. Clamp velocity so noisy
    /// sparse detections do not whip the virtual camera from side to side.
    static func focusPath(_ focus: [Double]) -> [Double] {
        var previous = 0.5
        return focus.map {raw in
            let target = raw.isFinite && 0...1 ~= raw ? min(0.85, max(0.15, raw)) : previous
            previous += min(0.08, max(-0.08, (target - previous) * 0.5))
            return previous
        }
    }
}
