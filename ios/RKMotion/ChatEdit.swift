import Foundation

/// Edits asked for in words: "make it half a minute", "more slow motion",
/// "no whoosh", "find the dog". Hebrew phrases are read by rules first; what
/// they miss goes to the on-device language model, which answers in the
/// same short commands.
enum ChatEdit {
    enum Command: Equatable {
        case length(String), shorter, longer
        case maxClip(String)
        case slowMode(String), slower
        case transition(String)
        case flag(String, Bool)
        case speed(String), faster
        case aspect(String)
        case kind(ContentKind)
        case search(String)
        case shuffle
    }

    /// The lengths "shorter" and "longer" step through, in seconds.
    static let lengthSteps = [15.0, 30, 45, 60, 90]
    static let speeds = ["1", "1.25", "1.5", "2"]

    // MARK: Commands from the model

    /// The commands as the model is asked to write them, one a line.
    static let commandList = """
        length <seconds or all> | shorter | longer | clip <max seconds per clip or off> | \
        slow <off, peak or each> | slower | transition <smart, cut, dissolve, fade, flash, slide or zoom> | \
        hook <on or off> | beatzoom <on or off> | whoosh <on or off> | ramp <on or off> | \
        mute <on or off> (the video's own sound) | music <on or off> | speed <1, 1.25, 1.5 or 2> | faster | \
        frame <story or wide> | kind <\(ContentKind.allCases.map(\.rawValue).joined(separator: ", "))> | \
        search <what to find, in English> | shuffle
        """
    /// One line of the model's answer as a command, or nil.
    static func command(_ line: String) -> Command? {
        let words = line.lowercased().split(whereSeparator: {$0 == " " || $0 == ":" || $0 == "-" || $0 == "*" || $0 == "•"}).map(String.init)
        guard let name = words.first else {return nil}
        let value = words.dropFirst().first ?? ""
        let rest = words.dropFirst().joined(separator: " ")
        var toggle: Bool?
        if ["on", "yes", "true"].contains(value) {toggle = true} else if ["off", "no", "false"].contains(value) {toggle = false}
        switch name {
        case "length":
            if value == "all" {return Command.length("all")}
            guard let seconds = Double(value), seconds >= 5, seconds <= 600 else {return nil}
            return Command.length(String(Int(seconds)))
        case "shorter": return .shorter
        case "longer": return .longer
        case "clip":
            if value == "off" {return Command.maxClip("off")}
            guard let seconds = Double(value), seconds >= 1, seconds <= 60 else {return nil}
            return Command.maxClip(String(Int(seconds)))
        case "slow": return SlowMotion.modes.contains(value) ? .slowMode(value) : nil
        case "slower": return .slower
        case "transition":
            let style = value == "smart" ? SmartTransitions.name : value
            return ([SmartTransitions.name, "cut", "dissolve", "fade", "flash", "slide", "zoom"]).contains(style) ? .transition(style) : nil
        case "hook": return toggle.map {Command.flag("hook", $0)}
        case "beatzoom": return toggle.map {Command.flag("beatZoom", $0)}
        case "whoosh": return toggle.map {Command.flag("whoosh", $0)}
        case "ramp": return toggle.map {Command.flag("speedRamp", $0)}
        case "mute": return toggle.map {Command.flag("muteOriginal", $0)}
        case "music": return toggle.map {Command.flag("useMusic", $0)}
        case "speed": return speeds.contains(value) ? .speed(value) : nil
        case "faster": return .faster
        case "frame":
            if value == "story" {return Command.aspect("9:16")}
            return value == "wide" ? Command.aspect("source") : nil
        case "kind": return ContentKind(rawValue: value).map {Command.kind($0)}
        case "search": return rest.isEmpty ? nil : .search(rest)
        case "shuffle": return .shuffle
        default: return nil
        }
    }
    static func commands(fromModel answer: String) -> [Command] {
        answer.split(whereSeparator: \.isNewline).compactMap {command(String($0).trimmingCharacters(in: .whitespaces))}
    }
}

#if canImport(FoundationModels)
import FoundationModels
#endif

extension ChatEdit {
    /// What the on-device model reads the request as, when Apple Intelligence is ready.
    static func modelCommands(_ text: String) async -> [Command] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {return []}
            let session = LanguageModelSession(instructions: """
                You turn a request to change a short phone movie into commands, one per line, from this list only: \
                \(commandList). Write nothing else. If nothing fits, write none.
                """)
            guard let answer = try? await session.respond(to: text) else {return []}
            return commands(fromModel: answer.content)
        }
        #endif
        return []
    }
}

extension ChatEdit {
    /// How a command is told back to the rider.
    static func describe(_ command: Command, settings: [String: Setting]) -> String {
        func onOff(_ on: Bool) -> String {on ? NSLocalizedString("פועל", comment: "A switch turned on") : NSLocalizedString("כבוי", comment: "A switch turned off")}
        switch command {
        case .length("all"): return NSLocalizedString("כל הקטעים בסרט", comment: "Chat edit done: every clip kept")
        case .maxClip("off"): return NSLocalizedString("בלי הגבלה לאורך קטע", comment: "Chat edit done: no clip length limit")
        case .length(let value): return String(format: NSLocalizedString("אורך הסרט %@ שניות", comment: "Chat edit done: movie length"), value)
        case .shorter, .longer: return String(format: NSLocalizedString("אורך הסרט %@ שניות", comment: "Chat edit done: movie length"), settings["targetLength"]?.string ?? Edit.defaultLength)
        case .maxClip(let value): return String(format: NSLocalizedString("עד %@ שניות לקטע", comment: "Chat edit done: clip length limit"), value)
        case .slowMode(let mode):
            switch mode {
            case "off": return NSLocalizedString("בלי הילוך איטי", comment: "Chat edit done: no slow motion")
            case "each": return NSLocalizedString("הילוך איטי בכל קטע", comment: "Chat edit done: slow motion on every clip")
            default: return NSLocalizedString("הילוך איטי ברגע השיא", comment: "Chat edit done: slow motion on the peak")
            }
        case .slower: return String(format: NSLocalizedString("הילוך איטי פי %@", comment: "Chat edit done: slow motion factor"), settings["slowRate"]?.string ?? "2")
        case .transition(let style): return String(format: NSLocalizedString("מעברים: %@", comment: "Style summary: the transitions"), StyleSheetNames.transition(style))
        case .flag(let key, let on):
            let name: String
            switch key {
            case "hook": name = NSLocalizedString("פתיח הוק", comment: "Opening hook switch")
            case "beatZoom": name = NSLocalizedString("זום על הביט", comment: "Beat zoom switch")
            case "whoosh": name = NSLocalizedString("סאונד ווש במעברים", comment: "Whoosh switch")
            case "speedRamp": name = NSLocalizedString("האצה לפני ואחרי ההאטה", comment: "Speed ramp switch")
            case "muteOriginal": return on ? NSLocalizedString("קול המקור מושתק", comment: "Chat edit done: source sound muted") : NSLocalizedString("קול המקור נשמע", comment: "Chat edit done: source sound kept")
            case "useMusic": return on ? NSLocalizedString("עם מוזיקה", comment: "Chat edit done: music on") : NSLocalizedString("בלי מוזיקה", comment: "Chat edit done: music off")
            default: name = key
            }
            return name + ": " + onOff(on)
        case .speed, .faster: return String(format: NSLocalizedString("מהירות %@×", comment: "Chat edit done: playback speed"), settings["speed"]?.string ?? "1")
        case .aspect(let value): return value == "9:16" ? NSLocalizedString("סטורי 9:16", comment: "Story framing") : NSLocalizedString("מסגרת המקור", comment: "Chat edit done: source framing")
        case .kind(let kind): return kind.title
        case .search(let query): return query
        case .shuffle: return NSLocalizedString("סדר חדש לקטעים", comment: "Chat edit done: clips shuffled")
        }
    }
    /// What each kind of change does to the clips: nothing, a new choice
    /// for the length, or new suggestions under a new clip rule.
    enum Reach {case nothing, length, suggestions}
    /// Applies the setting commands to `settings`; kind, search and shuffle are the model's to run.
    static func apply(_ commands: [Command], to settings: inout [String: Setting], currentLength: Double?) -> Reach {
        var reach = Reach.nothing
        func timing() {if reach == .nothing {reach = .length}}
        for command in commands {
            switch command {
            case .length(let value): settings["targetLength"] = .text(value); timing()
            case .shorter, .longer:
                let now = Double(settings["targetLength"]?.string ?? Edit.defaultLength) ?? currentLength ?? 60
                let step: Double?
                if case .shorter = command {step = lengthSteps.last {$0 < now - 0.5} ?? lengthSteps.first}
                else {step = lengthSteps.first {$0 > now + 0.5} ?? lengthSteps.last}
                if let step {settings["targetLength"] = .text(String(Int(step)))}
                timing()
            case .maxClip(let value): settings["maxClip"] = .text(value); reach = .suggestions
            case .slowMode(let mode): settings["slowMode"] = .text(mode); timing()
            case .slower:
                let rate = SlowMotion.rate(settings)
                settings["slowRate"] = .text(SlowMotion.rates.first {(Double($0) ?? 0) > rate + 0.01} ?? SlowMotion.rates.last!)
                if SlowMotion.mode(settings) == "off" {settings["slowMode"] = .text("peak")}
                timing()
            case .transition(let style): settings["transition"] = .text(style); timing()
            case .flag(let key, let on):
                settings[key] = .flag(on)
                if ["hook", "speedRamp"].contains(key) {timing()}
            case .speed(let value): settings["speed"] = .text(value); timing()
            case .faster:
                let now = settings["speed"]?.string ?? "1"
                settings["speed"] = .text(speeds.first {(Double($0) ?? 0) > (Double(now) ?? 1) + 0.01} ?? speeds.last!)
                timing()
            case .aspect(let value): settings["aspect"] = .text(value)
            case .kind, .search, .shuffle: break
            }
        }
        return reach
    }
}
