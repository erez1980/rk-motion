import Foundation

/// Grounded, local summaries and a shooting suggestion, derived from evidence
/// the scan actually retained. No generated speed, place, identity or emotion.
enum AutomaticInsights {
    struct Insight: Codable, Equatable {
        var eventID: String
        var file: String
        var start: Double
        var end: Double
        var text: String
    }
    struct Report: Codable {
        var schema = 2
        var insights: [Insight]
        var nextShot: String
        var labels: [String]
        var generatedAt = Date()
    }
    static func make(_ run: AutomaticRun, signals: Signals, project: LocalProject) -> Report {
        let selected = run.events.filter {event in run.edit.clips.contains {$0.uid == event.id}}
        let insights = selected.compactMap {event -> Insight? in
            guard let part = project.pieces.first(where: {
                $0.file == event.file && event.start >= $0.start && event.end <= $0.end + 0.001
            }) else {return nil}
            return Insight(eventID: event.id, file: event.file, start: event.start - part.start,
                           end: min(part.duration, event.end - part.start), text: event.title)
        }
        let reasons = Set(selected.map(\.reason))
        let suggestion: String
        if !reasons.contains(.scenery) {
            suggestion = NSLocalizedString("בפעם הבאה: צילום רחב של המקום יעזור לפתוח את הסיפור.", comment: "Automatic missing shot suggestion")
        } else if !reasons.contains(.people) && !reasons.contains(.reaction) && !reasons.contains(.speech) {
            suggestion = NSLocalizedString("בפעם הבאה: תגובה קצרה של המשתתפים תוסיף לסיפור הקשר אישי.", comment: "Automatic missing shot suggestion")
        } else {
            suggestion = NSLocalizedString("יש בחומר שילוב של הקשר ורגעים בולטים. המקורות נשארו זמינים לכל גרסה נוספת.", comment: "Automatic shooting coverage summary")
        }
        let labels = signals.scenes.filter {$0.value.isFinite && $0.value >= 0.2}.sorted {$0.value != $1.value ? $0.value > $1.value : $0.key < $1.key}.prefix(12).map(\.key)
        return Report(insights: insights, nextShot: suggestion, labels: labels)
    }
    /// Captions reference the chosen SOURCE windows. They are not falsely
    /// labelled movie-time subtitles after speed ramps and transitions.
    static func sourceNotes(_ report: Report) -> String {
        report.insights.map {"\($0.file) · \(RK.clock($0.start))–\(RK.clock($0.end)) · \($0.text)"}.joined(separator: "\n")
    }
}

enum AutomaticSync {
    struct Alignment: Equatable {var offset: Double; var correlation: Double}
    /// offset means left time = right time + offset. Difference envelopes
    /// reduce false agreement on a constant hum. Independent runner-up lags
    /// reject periodic/ambiguous sound rather than invent synchronization.
    static func align(_ left: [Double], _ right: [Double], rate: Double, maxLag: Double = 30) -> Alignment? {
        guard rate.isFinite, rate > 0, maxLag.isFinite, maxLag >= 0, left.count >= 12, right.count >= 12,
              left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else {return nil}
        let a = zip(left, left.dropFirst()).map {max(0, $1 - $0)}, b = zip(right, right.dropFirst()).map {max(0, $1 - $0)}
        let limit = min(Int(maxLag * rate), max(a.count, b.count) - 10)
        var candidates: [(lag: Int, score: Double)] = []
        for lag in -limit...limit {
            let from = max(0, lag), end = min(a.count, b.count + lag)
            guard end - from >= max(10, Int(rate * 2)) else {continue}
            let strideBy = max(1, (end - from) / 600)
            let points = Array(stride(from: from, to: end, by: strideBy))
            let meanA = points.reduce(0) {$0 + a[$1]} / Double(points.count)
            let meanB = points.reduce(0) {$0 + b[$1 - lag]} / Double(points.count)
            var dot = 0.0, aa = 0.0, bb = 0.0
            for index in points {let x = a[index] - meanA, y = b[index - lag] - meanB; dot += x * y; aa += x * x; bb += y * y}
            guard aa > 1e-8, bb > 1e-8 else {continue}
            candidates.append((lag, dot / sqrt(aa * bb)))
        }
        candidates.sort {$0.score != $1.score ? $0.score > $1.score : abs($0.lag) < abs($1.lag)}
        guard let best = candidates.first, best.score >= 0.85 else {return nil}
        let other = candidates.first {abs($0.lag - best.lag) > max(1, Int(rate / 2))}
        guard best.score - (other?.score ?? 0) > 0.1 else {return nil}
        return Alignment(offset: Double(best.lag) / rate, correlation: best.score)
    }
}
