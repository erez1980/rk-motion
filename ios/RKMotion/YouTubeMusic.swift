import Foundation
import YouTubeKit

/// Adds a song to a project from a YouTube link. Not for an App Store build:
/// guideline 5.2.3 bars downloading from YouTube.
enum YouTubeMusic {
    typealias Progress = @Sendable (Double) async -> Void

    /// A shared link usually arrives inside a sentence, not on its own.
    static func link(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {return nil}
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let host = url.host?.lowercased() else {continue}
            if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") {return url}
        }
        return nil
    }

    /// A video title is arbitrary text, and it becomes a file name.
    static func fileName(for title: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let words = title.components(separatedBy: banned).joined(separator: " ").split(whereSeparator: \.isWhitespace)
        let name = String(words.joined(separator: " ").prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return (name.isEmpty ? "YouTube" : name) + ".m4a"
    }

    /// A 200 carries the whole file. A 206 may legitimately return less than
    /// was asked for, so once the size is known only reaching it ends the
    /// download; without a size, a short piece is the only end marker left.
    static func finished(status: Int, received: Int, requested: Int, offset: Int, total: Int?) -> Bool {
        if status == 200 {return true}
        if let total {return offset >= total}
        return received < requested
    }

    /// Extracts on this iPhone and downloads the best audio stream AVFoundation
    /// can read. Extraction stays local: the library can also fall back to a
    /// remote server, which would hand the video to a third party.
    static func download(_ link: URL, into folder: URL, progress: Progress) async throws -> URL {
        let video = YouTube(url: link, methods: [.local])
        let streams = try await video.streams
        guard let stream = streams.filterAudioOnly().filter({$0.isNativelyPlayable}).highestAudioBitrateStream() else {
            throw AppError(message: "לא נמצא בסרטון שמע שהאייפון יכול לנגן.")
        }
        let title = (try? await video.metadata)?.title ?? ""
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName(for: title))
        try? FileManager.default.removeItem(at: target)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {throw AppError(message: "לא ניתן לשמור את השמע באייפון.")}
        do {
            let handle = try FileHandle(forWritingTo: target)
            defer {try? handle.close()}
            // YouTube slows one long request on an adaptive stream down to
            // playback speed, so the file is fetched in ranged pieces.
            let chunk = 4 << 20
            var offset = 0, total: Int?
            while true {
                try Task.checkCancellation()
                var request = URLRequest(url: stream.url)
                request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode), !data.isEmpty else {
                    throw AppError(message: "YouTube סירב להוריד את השמע. נסו שוב מאוחר יותר.")
                }
                try handle.write(contentsOf: data); offset += data.count
                if total == nil, http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
                   let size = Int(range.split(separator: "/").last ?? "") {
                    total = size
                    // The file is moved into the project, which skips the import's
                    // space check, so hold the app's usual reserve here instead.
                    try LocalStore.checkSpace(required: Int64(max(0, size - offset)) + 256 * 1024 * 1024)
                }
                await progress(min(1, Double(offset) / Double(max(1, total ?? offset))))
                if finished(status: http.statusCode, received: data.count, requested: chunk, offset: offset, total: total) {break}
            }
        } catch {
            try? FileManager.default.removeItem(at: target); throw error
        }
        return target
    }
}
