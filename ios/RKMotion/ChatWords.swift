import Foundation

// The Hebrew words requests are read by. They are matched, never shown,
// so they stay out of the string catalog (see scripts/check-ios-store.py).
extension ChatEdit {
    private static let negators: Set<String> = ["בלי", "ללא", "תוריד", "הורד", "להוריד", "תורידי", "תבטל", "בטל", "לבטל", "תבטלי", "תכבה", "כבה", "לכבות", "לא", "אל", "תעיף", "תסיר", "הסר", "להסיר", "no", "without", "remove", "off"]
    private static let numbers: [(String, Int)] = [
        ("ארבעים וחמש", 45), ("חמש עשרה", 15), ("חמישה עשר", 15), ("שלושים", 30), ("ארבעים", 40), ("עשרים", 20), ("שישים", 60), ("תשעים", 90),
        ("עשר", 10), ("שמונה", 8), ("שבע", 7), ("שש", 6), ("חמש", 5), ("ארבע", 4), ("שלוש", 3), ("שתי", 2), ("שני", 2),
    ]
    private static let kinds: [(String, ContentKind)] = [
        ("טיול", .trip), ("מסיבה", .party), ("חתונה", .party), ("אירוע", .party), ("רכיבה", .action), ("אקשן", .action),
        ("הרצאה", .talk), ("נאום", .talk), ("ילדים", .family), ("משפחה", .family), ("כלב", .pets), ("חתול", .pets), ("חיות", .pets),
        ("ספורט", .sports), ("אימון", .sports), ("נוף", .scenery), ("טבע", .scenery), ("אוכל", .food), ("מסעדה", .food),
    ]
    private static let searchMarkers = ["תוסיף את הקטעים עם", "תוסיף את הרגעים עם", "תוסיף קטעים עם", "תוסיף רגעים עם", "הוסף קטעים עם", "הוסף רגעים עם",
                                        "תמצא לי", "תמצא את", "תמצא", "מצא", "תחפש", "חפש", "איפה רואים", "קטעים עם", "רגעים עם", "קטעים של", "רגעים של", "find", "search"]

    /// The text as words: lower case, no points or punctuation, and the
    /// Hebrew number words as digits.
    static func normalized(_ text: String) -> String {
        var clean = String(text.lowercased().unicodeScalars.filter {!(0x0591...0x05C7).contains($0.value)}.map(Character.init))
        clean = clean.map {$0.isLetter || $0.isNumber || $0 == ":" || $0 == "." || $0 == "'" ? $0 : " "}.reduce(into: "") {$0.append($1)}
        var words = " " + clean.split(separator: " ").joined(separator: " ") + " "
        for (word, value) in numbers {
            for prefix in ["", "ל", "ב", "ו"] {words = words.replacingOccurrences(of: " " + prefix + word + " ", with: " " + prefix + "\(value) ")}
        }
        return words.trimmingCharacters(in: .whitespaces)
    }
    /// Whether one of `phrases` is in `text` as whole words, a joined "and"/"the"/"to" allowed in front.
    static func has(_ text: String, _ phrases: [String]) -> Bool {position(text, phrases) != nil}
    private static func position(_ text: String, _ phrases: [String]) -> Range<String.Index>? {
        let padded = " " + text + " "
        for phrase in phrases {
            for prefix in ["", "ו", "ה", "ל", "ב", "וה", "של", "ש"] {
                if let range = padded.range(of: " " + prefix + phrase + " ") ?? (phrase.hasSuffix(" ") ? nil : padded.range(of: " " + prefix + phrase)) {
                    // Back on `text`'s own indices: the padding added one leading space.
                    let lower = text.index(text.startIndex, offsetBy: max(0, padded.distance(from: padded.startIndex, to: range.lowerBound)), limitedBy: text.endIndex) ?? text.endIndex
                    return lower..<lower
                }
            }
        }
        return nil
    }
    /// Whether a word that turns something off stands just before the first of `phrases`.
    static func negated(_ text: String, _ phrases: [String]) -> Bool {
        guard let at = position(text, phrases) else {return false}
        // Back to three words, stopping where an "and" starts another part of the request.
        for word in text[..<at.lowerBound].split(separator: " ").suffix(3).reversed().map(String.init) {
            if negators.contains(word) || (word.hasPrefix("ו") && negators.contains(String(word.dropFirst()))) {return true}
            if word.hasPrefix("ו") && word.count > 2 {return false}
        }
        return false
    }
    /// The first number in `text` with "seconds" after it.
    private static func seconds(_ text: String) -> (value: Double, clip: Bool)? {
        let words = text.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let digits = word.drop {!$0.isNumber}
            guard let value = Double(digits), value > 0, index + 1 < words.count,
                  ["שניות", "שנייה", "שניה", "שנ'", "sec", "seconds", "s"].contains(words[index + 1]) else {continue}
            // "up to 3 seconds a clip" is about the clips, not the movie.
            let around = words[max(0, index - 3)..<min(words.count, index + 5)].joined(separator: " ")
            return (value, has(around, ["קטע", "קטעים", "כל קטע", "clip", "clips"]))
        }
        return nil
    }

    /// The commands a request asks for, read by rules; empty when none fit.
    static func commands(from text: String) -> [Command] {
        let text = normalized(text)
        guard !text.isEmpty else {return []}
        // A search takes the rest of the request as what to look for.
        for marker in searchMarkers {
            guard let range = (" " + text + " ").range(of: " " + marker + " ") else {continue}
            let query = String((" " + text + " ")[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !query.isEmpty, !query.contains(where: \.isNumber), !has(query, ["שניות", "שנייה"]) {return [.search(query)]}
        }
        var found: [Command] = []
        // "This is a trip", "edit it as a party".
        if let kind = kinds.first(where: {word, _ in
            has(text, ["זה " + word, "זה ה" + word, "זה סרטון של " + word, "זה סרטון של ה" + word, "תערוך כ" + word, "תערוך את זה כ" + word, "סוג " + word])
        })?.1 {found.append(.kind(kind))}
        // Length of the movie and of each clip.
        if has(text, ["קטעים קצרים", "קטעים יותר קצרים"]) {found.append(.maxClip("3"))}
        else if has(text, ["קטעים ארוכים", "קטעים יותר ארוכים"]) {found.append(.maxClip("off"))}
        if let asked = seconds(text) {
            found.append(asked.clip ? .maxClip(String(Int(asked.value))) : .length(String(Int(asked.value))))
        } else if has(text, ["דקה וחצי", "90 דקות"]) {found.append(.length("90"))}
        else if has(text, ["חצי דקה"]) {found.append(.length("30"))}
        else if has(text, ["2 דקות", "דקותיים"]) {found.append(.length("120"))}
        else if has(text, ["דקה", "1 דקה", "דקה אחת"]) {found.append(.length("60"))}
        else if has(text, ["כל הקטעים", "את הכל", "הכל"]) && has(text, ["תכניס", "תשים", "תשאיר", "עם"]) {found.append(.length("all"))}
        else if has(text, ["קצר יותר", "יותר קצר", "תקצר", "לקצר", "קצר"]) && !found.contains(where: {if case .maxClip = $0 {return true}; return false}) {found.append(.shorter)}
        else if has(text, ["ארוך יותר", "יותר ארוך", "תאריך", "להאריך", "ארוך"]) && !found.contains(where: {if case .maxClip = $0 {return true}; return false}) {found.append(.longer)}
        // Slow motion.
        let slow = ["הילוך איטי", "הילוך האיטי", "הילוך אטי", "האטה", "האטות", "סלואו", "slow motion", "slowmo", "slow mo"]
        if has(text, slow) {
            if negated(text, slow) {found.append(.slowMode("off"))}
            else if has(text, ["בכל קטע", "בכל הקטעים", "יותר הילוך איטי", "הרבה הילוך איטי", "בכל מקום"]) {found.append(.slowMode("each"))}
            else {found.append(.slowMode("peak"))}
        }
        if has(text, ["איטי יותר", "יותר איטי", "יותר לאט", "לאט יותר"]) {found.append(.slower)}
        // The switches.
        let ramp = ["האצה", "ספיד ראמפ", "speed ramp", "רמפה", "ramp"]
        if has(text, ramp) {found.append(.flag("speedRamp", !negated(text, ramp)))}
        let hook = ["הוק", "פתיח", "hook"]
        if has(text, hook) {found.append(.flag("hook", !negated(text, hook)))}
        let punch = ["זום על הביט", "זום בביט", "זום לביט", "זום עם הביט", "זום על הקצב", "זום בקצב", "beat zoom", "זומים"]
        let punched = has(text, punch)
        if punched {found.append(.flag("beatZoom", !negated(text, punch)))}
        let whoosh = ["ווש", "וווש", "וואוש", "whoosh", "סאונד מעבר", "סאונד במעברים", "רעש במעברים", "משב"]
        if has(text, whoosh) {found.append(.flag("whoosh", !negated(text, whoosh)))}
        // Sound: the source's own, and the song.
        let source = ["קול המקור", "סאונד המקור", "קול מקורי", "סאונד מקורי", "הקול המקורי", "הסאונד המקורי", "קולות", "הקול של הסרטון", "דיבור"]
        if has(text, source) {
            found.append(.flag("muteOriginal", negated(text, source) || has(text, ["תשתיק", "השתק", "להשתיק"])))
        } else if has(text, ["תשתיק", "השתק", "להשתיק", "mute"]) && !has(text, ["מוזיקה", "שיר", "music"]) {
            found.append(.flag("muteOriginal", true))
        }
        let music = ["מוזיקה", "מוסיקה", "שיר", "השיר", "music"]
        if has(text, music), !has(text, source) {
            if negated(text, music) || has(text, ["תשתיק", "השתק"]) {found.append(.flag("useMusic", false))}
            else if has(text, ["עם", "תחזיר", "תוסיף", "החזר"]) {found.append(.flag("useMusic", true))}
        }
        // Transitions.
        let transitions = ["מעבר", "מעברים", "מעברי"]
        if has(text, ["בלי מעברים", "ללא מעברים", "חיתוך", "חיתוכים", "חיתוכים חדים"]) {found.append(.transition("cut"))}
        else if has(text, ["המסה", "מעברים רכים", "מעברים חלקים", "dissolve"]) {found.append(.transition("dissolve"))}
        else if has(text, ["דעיכה", "לשחור", "fade"]) {found.append(.transition("fade"))}
        else if has(text, ["הבזק", "פלאש", "flash"]) {found.append(.transition("flash"))}
        else if has(text, ["החלקה", "slide"]) {found.append(.transition("slide"))}
        else if !punched && has(text, ["זום"]) && has(text, transitions) {found.append(.transition("zoom"))}
        else if has(text, ["מעברים חכמים", "חכם", "smart"]) && has(text, transitions) {found.append(.transition(SmartTransitions.name))}
        // Pace and framing.
        if has(text, ["מהירות רגילה", "בלי האצה של הסרט"]) {found.append(.speed("1"))}
        else if has(text, ["מהירות כפולה", "פי 2 מהר"]) {found.append(.speed("2"))}
        else if has(text, ["מהר יותר", "יותר מהר", "תאיץ", "תזרז", "faster"]) {found.append(.faster)}
        if has(text, ["לרוחב", "אופקי", "רוחבי", "landscape", "16:9"]) {found.append(.aspect("source"))}
        else if has(text, ["לאורך", "אנכי", "סטורי", "ריל", "רילס", "טיקטוק", "9:16", "portrait"]) {found.append(.aspect("9:16"))}
        if has(text, ["ערבב", "תערבב", "לערבב", "סדר אקראי", "shuffle"]) {found.append(.shuffle)}
        return found
    }
}
