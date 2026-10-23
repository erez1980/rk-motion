import Foundation
import CoreImage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The strongest moment of the chosen footage, by the scan's own scores.
enum Highlights {
    /// The clip and the source moment, mid-second, that scored highest.
    static func peak(_ clips: [Clip], scores: [Double]) -> (clip: Int, time: Double)? {
        var best: (clip: Int, time: Double, score: Double)?
        for (index, clip) in clips.enumerated() {
            let first = max(0, Int(clip.start)), last = min(scores.count - 1, Int(ceil(clip.end)) - 1)
            guard first <= last else {continue}
            for second in first...last {
                let at = Double(second) + 0.5
                guard at >= clip.start, at <= clip.end, scores[second].isFinite else {continue}
                if best == nil || scores[second] > best!.score {best = (index, at, scores[second])}
            }
        }
        return best.map {($0.clip, $0.time)}
    }
    /// The clips with slow motion on the strongest moment only, starting a
    /// little before it so the build-up is seen slowed too.
    static func slowed(_ clips: [Clip], scores: [Double]) -> [Clip] {
        var result = clips.map {clip -> Clip in var clip = clip; clip.slowAt = nil; return clip}
        guard let peak = peak(clips, scores: scores) else {return result}
        result[peak.clip].slowAt = peak.time - Clip.slowSpan / 2
        return result
    }
    /// When the strongest moment plays in the movie, in movie seconds.
    static func peakTime(_ clips: [Clip], scores: [Double], speed: Double, transition: Double) -> Double? {
        guard let peak = peak(clips, scores: scores) else {return nil}
        let segments = LocalEngine.timeline(clips: clips, speed: speed, transition: transition)
        return segments[peak.clip].start + clips[peak.clip].screenOffset(of: peak.time, speed: speed)
    }
}

/// Where a song "drops": the moment its energy jumps the most and stays up.
enum Drop {
    /// `levels` are the song's loudness at `rate` slices a second, 0…1.
    static func find(_ levels: [Double], rate: Double) -> Double? {
        let window = max(1, Int((4 * rate).rounded()))
        guard rate > 0, levels.count > window * 2 else {return nil}
        var sums = [0.0]
        for value in levels {sums.append(sums.last! + (value.isFinite ? value : 0))}
        func mean(_ from: Int, _ to: Int) -> Double {(sums[to] - sums[from]) / Double(to - from)}
        let loudest = (0...(levels.count - window)).map {mean($0, $0 + window)}.max() ?? 0
        var best: (index: Int, rise: Double)?
        for index in window...(levels.count - window) {
            let after = mean(index, index + window), before = mean(index - window, index)
            // A drop lands in the song's loud part, not on a small swell in a quiet one.
            guard after >= loudest * 0.75 else {continue}
            let rise = after - before
            if best == nil || rise > best!.rise {best = (index, rise)}
        }
        guard let best, best.rise >= 0.08 else {return nil}
        return Double(best.index) / rate
    }
    /// The song start that puts its drop on the movie's strongest moment;
    /// nil when the drop comes too early in the song to reach it.
    static func start(drop: Double, peak: Double) -> Double? {
        let start = drop - peak
        return start >= 0 ? start : nil
    }
}

/// Lowers the music while people talk, laugh or cheer in the kept footage.
enum Ducking {
    /// The music's share of its volume while it gives way.
    static let low: Float = 0.35
    static let ramp = 0.25

    /// Movie-time stretches where the source sound has speech or cheering.
    static func intervals(clips: [Clip], segments: [LocalEngine.Segment], speech: [Double], cheer: [Double], speed: Double) -> [(start: Double, end: Double)] {
        var found: [(start: Double, end: Double)] = []
        for (index, clip) in clips.enumerated() where index < segments.count {
            let first = max(0, Int(clip.start)), last = Int(ceil(clip.end)) - 1
            guard first <= last else {continue}
            for second in first...last {
                let voice = second < speech.count ? speech[second] : 0, joy = second < cheer.count ? cheer[second] : 0
                guard max(voice, joy) >= 0.5 else {continue}
                let from = segments[index].start + clip.screenOffset(of: max(Double(second), clip.start), speed: speed)
                let to = segments[index].start + clip.screenOffset(of: min(Double(second + 1), clip.end), speed: speed)
                if to > from {found.append((from, to))}
            }
        }
        // Short breaths between words keep the music down.
        var merged: [(start: Double, end: Double)] = []
        for stretch in found.sorted(by: {$0.start < $1.start}) {
            if let last = merged.last, stretch.start - last.end < 0.75 {merged[merged.count - 1].end = max(last.end, stretch.end)}
            else {merged.append(stretch)}
        }
        return merged
    }
    /// The music's volume through the movie as points joined by straight
    /// ramps: in from silence over the first `fadeIn` seconds, down around
    /// each stretch, then out over the last `fade` seconds.
    static func envelope(_ intervals: [(start: Double, end: Double)], volume: Float, length: Double, fade: Double = 3, fadeIn: Double = 0) -> [(time: Double, volume: Float)] {
        guard length > 0 else {return [(0, volume)]}
        let fadeStart = max(0, length - min(fade, length))
        // A short movie still rises from silence, over at most a quarter of it.
        let rising = fadeIn > 0 ? min(fadeIn, length / 4) : 0
        func level(_ time: Double) -> Float {
            var share: Float = 1
            for stretch in intervals {
                let value: Double
                if time >= stretch.start && time <= stretch.end {value = 0}
                else if time < stretch.start {value = min(1, (stretch.start - time) / ramp)}
                else {value = min(1, (time - stretch.end) / ramp)}
                share = min(share, low + (1 - low) * Float(value))
            }
            if rising > 0 && time < rising {share *= Float(time / rising)}
            // Inside the closing fade, as a short movie's rise can be.
            if time > fadeStart && length > fadeStart {share *= Float((length - time) / (length - fadeStart))}
            return share
        }
        var times = Set([0, fadeStart])
        if rising > 0 && rising < length {times.insert(rising)}
        for stretch in intervals {
            for time in [stretch.start - ramp, stretch.start, stretch.end, stretch.end + ramp] where time > 0 && time < fadeStart {times.insert(time)}
        }
        var points: [(time: Double, volume: Float)] = times.sorted().map {(time: $0, volume: volume * level($0))}
        points.append((time: length, volume: 0))
        return points
    }
}

/// Keeps people in frame when a wide video is cut to a tall 9:16 story.
enum Framing {
    /// Where across the frame people usually stand in a clip, 0 left … 1
    /// right; nil when the scan saw nobody there.
    static func focus(of clip: Clip, in focus: [Double]?) -> Double? {
        guard let focus, !focus.isEmpty else {return nil}
        let first = max(0, Int(clip.start)), last = min(focus.count - 1, Int(ceil(clip.end)) - 1)
        guard first <= last else {return nil}
        let seen = focus[first...last].filter {$0.isFinite && $0 >= 0 && $0 <= 1}.sorted()
        return seen.isEmpty ? nil : seen[seen.count / 2]
    }
    /// The sideways shift that puts `focus` in the middle of a frame
    /// `width` wide, for a picture `scaled` wide, without showing an edge.
    static func shift(focus: Double?, scaled: Double, width: Double) -> Double {
        let centred = (width - scaled) / 2
        guard let focus, scaled > width + 0.5 else {return centred}
        return min(0, max(width - scaled, width / 2 - focus * scaled))
    }
}

/// A colour grade that suits what the scan found the video to be.
enum Look {
    struct Grade: Equatable {
        var saturation = 1.0, contrast = 1.0, brightness = 0.0, vibrance = 0.0
        /// Positive warms (more red, less blue), negative cools.
        var warmth = 0.0
    }
    static func grade(for kind: ContentKind) -> Grade {
        switch kind {
        case .action: return Grade(saturation: 1.1, contrast: 1.08, vibrance: 0.35)
        case .party: return Grade(saturation: 1.15, contrast: 1.05, warmth: 0.05)
        case .trip: return Grade(vibrance: 0.5, warmth: 0.03)
        case .talk: return Grade(contrast: 1.03)
        case .family: return Grade(saturation: 1.05, brightness: 0.02, warmth: 0.05)
        case .pets: return Grade(saturation: 1.05, vibrance: 0.2, warmth: 0.03)
        case .sports: return Grade(saturation: 1.08, contrast: 1.08, vibrance: 0.3)
        case .scenery: return Grade(contrast: 1.04, vibrance: 0.55)
        case .food: return Grade(saturation: 1.12, contrast: 1.03, warmth: 0.06)
        case .general: return Grade(vibrance: 0.25)
        }
    }
    static func apply(_ grade: Grade, to image: CIImage) -> CIImage {
        var result = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: grade.saturation, kCIInputContrastKey: grade.contrast, kCIInputBrightnessKey: grade.brightness])
        if grade.vibrance != 0 {result = result.applyingFilter("CIVibrance", parameters: ["inputAmount": grade.vibrance])}
        if grade.warmth != 0 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + grade.warmth, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - grade.warmth, w: 0)])
        }
        return result.cropped(to: image.extent)
    }
}

/// A name, a line under it and a post caption for the movie, from the
/// on-device model when it is ready, else from what the scan found.
enum MovieWords {
    struct Words: Equatable {
        var title: String
        var subtitle: String
        var caption: String
    }
    static func fallback(for kind: ContentKind, date: Date) -> Words {
        let title: String, tags: String
        switch kind {
        case .action: title = NSLocalizedString("יום על הגלגלים", comment: "Suggested movie title"); tags = "#ride #adventure #action"
        case .party: title = NSLocalizedString("איזו מסיבה", comment: "Suggested movie title"); tags = "#party #celebration #goodvibes"
        case .trip: title = NSLocalizedString("יצאנו לטייל", comment: "Suggested movie title"); tags = "#trip #travel #explore"
        case .talk: title = NSLocalizedString("הרגעים החשובים", comment: "Suggested movie title"); tags = "#talk #moments"
        case .family: title = NSLocalizedString("רגעים משפחתיים", comment: "Suggested movie title"); tags = "#family #kids #love"
        case .pets: title = NSLocalizedString("החבר הכי טוב", comment: "Suggested movie title"); tags = "#pets #dog #cat #cute"
        case .sports: title = NSLocalizedString("יום של ספורט", comment: "Suggested movie title"); tags = "#sport #fitness #game"
        case .scenery: title = NSLocalizedString("נופים", comment: "Suggested movie title"); tags = "#nature #landscape #views"
        case .food: title = NSLocalizedString("בתיאבון", comment: "Suggested movie title"); tags = "#food #foodie #yum"
        case .general: title = NSLocalizedString("רגעים טובים", comment: "Suggested movie title"); tags = "#moments #memories"
        }
        let subtitle = date.formatted(date: .long, time: .omitted)
        return Words(title: title, subtitle: subtitle, caption: title + " ✨ " + tags)
    }
    static func suggest(for reading: ContentReading, date: Date, language: String?) async -> Words {
        let plain = fallback(for: reading.kind, date: date)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {return plain}
            let tongue = Locale(identifier: "en").localizedString(forLanguageCode: language ?? "en") ?? "English"
            let session = LanguageModelSession(instructions: """
                You name short personal videos shared on Instagram and WhatsApp. Write in \(tongue). \
                Answer with exactly three lines and nothing else:
                TITLE: a catchy title of at most 5 words
                SUBTITLE: a short line of at most 6 words
                CAPTION: an Instagram caption of one sentence with 3 to 5 hashtags
                """)
            do {
                let answer = try await session.respond(to: SongIdeas.prompt(for: reading, seconds: nil)
                    .replacingOccurrences(of: " Suggest 5 songs.", with: "") + " It was filmed on \(date.formatted(date: .long, time: .omitted)).")
                return parse(answer.content, fallback: plain)
            } catch {return plain}
        }
        #endif
        return plain
    }
    /// Reads the model's three labelled lines; a missing one keeps the fallback's.
    static func parse(_ text: String, fallback: Words) -> Words {
        var words = fallback
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value(_ label: String) -> String? {
                guard line.uppercased().hasPrefix(label + ":") else {return nil}
                let rest = line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*"))
                return rest.isEmpty ? nil : rest
            }
            if let title = value("TITLE") {words.title = String(title.prefix(Edit.titleLimit))}
            else if let subtitle = value("SUBTITLE") {words.subtitle = String(subtitle.prefix(Edit.titleLimit))}
            else if let caption = value("CAPTION") {words.caption = String(caption.prefix(400))}
        }
        return words
    }
}
