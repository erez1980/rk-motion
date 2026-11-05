import AVFoundation
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

    /// The most a song may weigh. An hour of the best audio YouTube offers is
    /// well under this; anything larger is not a song.
    static let sizeLimit = 512 << 20

    /// "bytes 0-1023/4096" (the size may be "*"), as the server's own account
    /// of which bytes a 206 carries.
    static func contentRange(_ header: String?) -> (first: Int, last: Int, total: Int?)? {
        guard let header, header.lowercased().hasPrefix("bytes ") else {return nil}
        let parts = header.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else {return nil}
        let span = parts[0].split(separator: "-", maxSplits: 1)
        guard span.count == 2, let first = Int(span[0].trimmingCharacters(in: .whitespaces)), let last = Int(span[1].trimmingCharacters(in: .whitespaces)),
              first >= 0, last >= first else {return nil}
        let size = parts[1].trimmingCharacters(in: .whitespaces)
        if size == "*" {return (first, last, nil)}
        guard let total = Int(size), total > last else {return nil}
        return (first, last, total)
    }

    /// Extracts on this iPhone and downloads the best audio stream AVFoundation
    /// can read. Extraction stays local: the library can also fall back to a
    /// remote server, which would hand the video to a third party.
    static func download(_ link: URL, into folder: URL, progress: Progress) async throws -> URL {
        let video = YouTube(url: link, methods: [.local])
        let stream = try await audioStream(of: video)
        let title = (try? await video.metadata)?.title ?? ""
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(fileName(for: title))
        try await fetch(stream.url, to: target, progress: progress)
        // A song that keeps its silent stretch is still a song, so a failed
        // repair leaves the download as it came; a cancel still cancels.
        do {try await trimToAudio(target)}
        catch is CancellationError {try? FileManager.default.removeItem(at: target); throw CancellationError()}
        catch {}
        return target
    }

    /// The address of a song's audio, to listen to before adding it. It is
    /// extracted on this iPhone like a download, and plays straight from
    /// YouTube without being saved.
    static func listeningURL(_ link: URL) async throws -> URL {
        try await audioStream(of: YouTube(url: link, methods: [.local])).url
    }
    private static func audioStream(of video: YouTube) async throws -> YouTubeKit.Stream {
        let streams = try await video.streams
        guard let stream = streams.filterAudioOnly().filter({$0.isNativelyPlayable}).highestAudioBitrateStream() else {
            throw AppError(message: "לא נמצא בסרטון שמע שהאייפון יכול לנגן.")
        }
        return stream
    }

    /// YouTube's audio is a fragmented MP4 whose header already states the
    /// song's whole length, and AVFoundation places the fragments after that
    /// length, so the song reads as twice as long with half of it silent.
    /// The samples are copied, without re-encoding and with the silent gap
    /// closed, into a plain file that holds only the music. An export session
    /// would keep the gap.
    static func trimToAudio(_ file: URL) async throws {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {return}
        let declared = try await asset.load(.duration)
        let audio = try audioLength(asset, track: track)
        guard audio.seconds > 0, declared.seconds - audio.seconds > 0.5 else {return}
        let output = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let reader = try AVAssetReader(asset: asset)
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(samples) else {throw damaged}
            reader.add(samples)
            let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: try await track.load(.formatDescriptions).first)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {throw damaged}
            writer.add(input)
            guard reader.startReading() else {throw reader.error ?? damaged}
            defer {reader.cancelReading()}
            guard writer.startWriting() else {throw writer.error ?? damaged}
            writer.startSession(atSourceTime: .zero)
            var gaps = GapCloser()
            while let sample = samples.copyNextSampleBuffer() {
                let shift = gaps.shift(for: sample)
                let moved = shift == .zero ? sample : try shifted(sample, by: shift)
                while !input.isReadyForMoreMediaData {
                    // A writer that fails (a full disk) never becomes ready again.
                    guard writer.status == .writing else {throw writer.error ?? damaged}
                    do {try await Task.sleep(nanoseconds: 2_000_000)} catch {writer.cancelWriting(); throw error}
                }
                guard input.append(moved) else {writer.cancelWriting(); throw writer.error ?? damaged}
            }
            guard reader.status == .completed else {writer.cancelWriting(); throw reader.error ?? damaged}
            input.markAsFinished()
            writer.endSession(atSourceTime: gaps.end)
            await writer.finishWriting()
            guard writer.status == .completed else {throw writer.error ?? damaged}
            _ = try FileManager.default.replaceItemAt(file, withItemAt: output)
        } catch {
            try? FileManager.default.removeItem(at: output); throw error
        }
    }
    /// How long the music lasts once silent gaps between samples are closed,
    /// read from the samples themselves rather than from the file's header.
    static func audioLength(_ asset: AVAsset, track: AVAssetTrack) throws -> CMTime {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {throw damaged}
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? damaged}
        defer {reader.cancelReading()}
        var gaps = GapCloser()
        while let sample = output.copyNextSampleBuffer() {_ = gaps.shift(for: sample)}
        guard reader.status == .completed else {throw reader.error ?? damaged}
        return gaps.end
    }
    /// Moves each sample back so it follows the one before it whenever a
    /// silent gap of more than a tenth of a second lies between them.
    struct GapCloser {
        private(set) var end = CMTime.zero
        private var offset = CMTime.zero
        mutating func shift(for sample: CMSampleBuffer) -> CMTime {
            let start = CMSampleBufferGetPresentationTimeStamp(sample), length = CMSampleBufferGetDuration(sample)
            guard start.isNumeric else {return offset}
            let placed = CMTimeAdd(start, offset)
            if CMTimeSubtract(placed, end).seconds > 0.1 {offset = CMTimeSubtract(end, start)}
            let finish = CMTimeAdd(CMTimeAdd(start, offset), length.isNumeric ? length : .zero)
            if finish > end {end = finish}
            return offset
        }
    }
    private static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count) == noErr else {throw damaged}
        for index in timing.indices {
            timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, offset)
            if timing[index].decodeTimeStamp.isNumeric {timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)}
        }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
              let copy else {throw damaged}
        return copy
    }

    /// Downloads `url` into `target` in ranged pieces. Each response streams
    /// to disk, so memory stays small whatever the server sends; every 206
    /// must carry exactly the bytes asked for, at the offset asked for, of a
    /// file whose size does not change; a 200 means the server ignored the
    /// range and is sending the whole file from its first byte, so the file
    /// starts over from that body. Nothing larger than `limit` is accepted.
    /// On any failure the partial file is removed.
    static func fetch(_ url: URL, to target: URL, session: URLSession = .shared, chunk: Int = 4 << 20, limit: Int = sizeLimit, progress: Progress) async throws {
        try? FileManager.default.removeItem(at: target)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {throw AppError(message: "לא ניתן לשמור את השמע באייפון.")}
        do {
            let handle = try FileHandle(forWritingTo: target)
            defer {try? handle.close()}
            // YouTube slows one long request on an adaptive stream down to
            // playback speed, so the file is fetched in ranged pieces.
            var offset = 0, total: Int?
            while true {
                try Task.checkCancellation()
                var request = URLRequest(url: url)
                request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
                let (body, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {throw refused}
                switch http.statusCode {
                case 206:
                    guard let range = contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                          range.first == offset, range.last < offset + chunk else {throw damaged}
                    if let size = range.total {
                        if let total, total != size {throw damaged}
                        if total == nil {
                            guard size <= limit else {throw tooLarge}
                            // The file is moved into the project, which skips the import's
                            // space check, so hold the app's usual reserve here instead.
                            try LocalStore.checkSpace(required: Int64(size - offset) + 256 * 1024 * 1024)
                        }
                        total = size
                    }
                    let expected = range.last - range.first + 1
                    guard offset + expected <= limit else {throw tooLarge}
                    let written = try await stream(body, into: handle, atMost: expected, overflow: damaged)
                    guard written == expected else {throw damaged}
                    offset += written
                    await progress(min(1, Double(offset) / Double(max(1, total ?? offset))))
                    if finished(status: 206, received: written, requested: chunk, offset: offset, total: total) {return}
                case 200:
                    if http.expectedContentLength > Int64(limit) {throw tooLarge}
                    try handle.truncate(atOffset: 0)
                    let written = try await stream(body, into: handle, atMost: limit, overflow: tooLarge)
                    guard written > 0, http.expectedContentLength < 0 || Int64(written) == http.expectedContentLength else {throw damaged}
                    await progress(1)
                    return
                default:
                    throw refused
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: target); throw error
        }
    }
    /// Writes a response body to disk in 64 KB pieces and returns its size,
    /// failing with `overflow` as soon as it runs past `atMost` bytes.
    private static func stream(_ body: URLSession.AsyncBytes, into handle: FileHandle, atMost: Int, overflow: AppError) async throws -> Int {
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var count = 0
        for try await byte in body {
            count += 1
            guard count <= atMost else {throw overflow}
            buffer.append(byte)
            if buffer.count == 1 << 16 {try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)}
        }
        if !buffer.isEmpty {try handle.write(contentsOf: buffer)}
        return count
    }
    private static var refused: AppError {AppError(message: "YouTube סירב להוריד את השמע. נסו שוב מאוחר יותר.")}
    private static var damaged: AppError {AppError(message: "ההורדה מ־YouTube הגיעה שבורה ונעצרה. נסו שוב.")}
    private static var tooLarge: AppError {AppError(message: "קובץ השמע גדול מדי לשיר.")}
}
