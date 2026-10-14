import Foundation

/// Finds songs on YouTube by name, on the iPhone, the way the web app's search
/// does with yt-dlp. YouTube has no public search without a developer key, so
/// this asks the endpoint its own web page uses and, failing that, reads the
/// results page itself.
enum YouTubeSearch {
    struct Result: Identifiable, Equatable {
        let id: String
        let title: String
        let channel: String
        let duration: Double
        let thumbnail: URL?
        var link: URL {URL(string: "https://www.youtube.com/watch?v=" + id)!}
    }

    static func search(_ query: String, limit: Int = 12) async throws -> [Result] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {return []}
        var answered = false
        do {
            let found = results(in: try await api(text), limit: limit)
            if !found.isEmpty {return found}
            answered = true
        } catch is CancellationError {throw CancellationError()} catch {}
        do {
            let found = results(in: try await page(text), limit: limit)
            if !found.isEmpty || answered {return found}
        } catch is CancellationError {throw CancellationError()} catch {if answered {return []}}
        throw AppError(message: "החיפוש ב־YouTube נכשל. בדקו את החיבור ונסו שוב.")
    }

    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func api(_ query: String) async throws -> Any {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20260708.00.00", "hl": language]],
            "query": query,
            "params": "EgIQAQ==", // Videos only: no channels, playlists or shorts shelves.
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw AppError(message: "החיפוש ב־YouTube נכשל. בדקו את החיבור ונסו שוב.")}
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func page(_ query: String) async throws -> Any {
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: query)]
        var request = URLRequest(url: parts.url!)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let html = String(data: data, encoding: .utf8),
              let json = initialData(in: html) else {throw AppError(message: "החיפוש ב־YouTube נכשל. בדקו את החיבור ונסו שוב.")}
        return try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    /// The results page carries its data as one JSON object assigned in a script.
    static func initialData(in html: String) -> String? {
        for marker in ["var ytInitialData = ", "window[\"ytInitialData\"] = ", "ytInitialData = "] {
            guard let start = html.range(of: marker)?.upperBound else {continue}
            if let end = html.range(of: ";</script>", range: start..<html.endIndex)?.lowerBound {return String(html[start..<end])}
        }
        return nil
    }

    /// YouTube moves its layout around often, so each video is found by the
    /// shape of its entry wherever it sits, not by a fixed path from the top.
    static func results(in json: Any, limit: Int = 12) -> [Result] {
        var found: [Result] = [], seen = Set<String>()
        func visit(_ node: Any) {
            guard found.count < limit else {return}
            if let object = node as? [String: Any] {
                for key in ["videoRenderer", "compactVideoRenderer", "videoWithContextRenderer"] {
                    if let entry = object[key] as? [String: Any], let result = result(entry), seen.insert(result.id).inserted {
                        found.append(result)
                    }
                }
                // Keys sorted: a dictionary's own order changes from run to run.
                for key in object.keys.sorted() where !["videoRenderer", "compactVideoRenderer", "videoWithContextRenderer"].contains(key) {
                    visit(object[key]!)
                }
            } else if let array = node as? [Any] {
                for item in array {visit(item)}
            }
        }
        visit(json)
        return found
    }

    private static func result(_ entry: [String: Any]) -> Result? {
        guard let id = entry["videoId"] as? String, id.count == 11,
              id.allSatisfy({$0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"}) else {return nil}
        // A live stream has no length and no end, so it cannot become a song.
        guard let length = text(entry["lengthText"]), let duration = seconds(length), duration > 0 else {return nil}
        let title = text(entry["title"]) ?? text(entry["headline"]) ?? ""
        let channel = text(entry["ownerText"]) ?? text(entry["longBylineText"]) ?? text(entry["shortBylineText"]) ?? ""
        let thumbnails = ((entry["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let picture = thumbnails.compactMap {$0["url"] as? String}.last.flatMap {
            URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0)
        }
        return Result(id: id, title: title.isEmpty ? "YouTube" : title, channel: channel, duration: duration, thumbnail: picture)
    }

    /// YouTube writes text either whole or as styled runs.
    static func text(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else {return nil}
        if let simple = object["simpleText"] as? String {return simple}
        if let runs = object["runs"] as? [[String: Any]] {
            let joined = runs.compactMap {$0["text"] as? String}.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// "3:45" or "1:02:03" to seconds.
    static func seconds(_ length: String) -> Double? {
        let parts = length.trimmingCharacters(in: .whitespaces).split(separator: ":").map {Int($0)}
        guard (2...3).contains(parts.count), !parts.contains(nil) else {return nil}
        return Double(parts.reduce(0) {$0 * 60 + $1!})
    }
}
