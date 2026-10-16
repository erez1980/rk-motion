import AVFoundation
import UIKit

/// The project list's pictures. Each is made once from the ride's first
/// frame, kept in memory and on disk, and at most `limit` are decoded at a
/// time; a row that scrolls away before its turn gives its turn up. The list
/// itself is lazy, so only rows on screen ask.
actor Thumbnails {
    static let shared = Thumbnails()
    typealias Maker = @Sendable (URL) async throws -> CGImage
    private let maker: Maker
    private let folder: URL
    private let limit: Int
    private let memory = NSCache<NSString, UIImage>()
    private var running = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []

    init(folder: URL? = nil, limit: Int = 2, maker: @escaping Maker = Thumbnails.firstFrame) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? caches.appendingPathComponent("thumbnails", isDirectory: true)
        self.limit = max(1, limit); self.maker = maker
        memory.countLimit = 240
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }
    static func firstFrame(_ url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 240, height: 180); generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: .zero).image
    }
    private func key(_ project: LocalProject) -> String {project.id + "-" + URL(fileURLWithPath: project.source).deletingPathExtension().lastPathComponent}
    private func file(_ key: String) -> URL {folder.appendingPathComponent(key + ".jpg")}

    func image(for project: LocalProject) async -> UIImage? {
        let key = key(project)
        if let hit = memory.object(forKey: key as NSString) {return hit}
        if let saved = UIImage(contentsOfFile: file(key).path) {memory.setObject(saved, forKey: key as NSString); return saved}
        guard await turn() else {return nil}
        defer {done()}
        // Another row may have made it while this one waited.
        if let hit = memory.object(forKey: key as NSString) {return hit}
        guard !Task.isCancelled, let frame = try? await maker(LocalStore.file(project.source, project: project.id)), !Task.isCancelled else {return nil}
        let image = UIImage(cgImage: frame)
        memory.setObject(image, forKey: key as NSString)
        if let data = image.jpegData(compressionQuality: 0.8) {try? data.write(to: file(key), options: .atomic)}
        return image
    }
    /// One moment of a video, small, for clip rows and the timeline strip.
    /// Kept in memory only: an edit's moments change too often to store.
    func frame(_ file: URL, at seconds: Double) async -> UIImage? {
        let key = file.lastPathComponent + "@" + String(format: "%.1f", seconds.isFinite ? max(0, seconds) : 0)
        if let hit = memory.object(forKey: key as NSString) {return hit}
        guard await turn() else {return nil}
        defer {done()}
        if let hit = memory.object(forKey: key as NSString) {return hit}
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.maximumSize = CGSize(width: 160, height: 160); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard !Task.isCancelled, let frame = try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image else {return nil}
        let image = UIImage(cgImage: frame)
        memory.setObject(image, forKey: key as NSString)
        return image
    }
    /// The home row's picture: the newest movie made from the project, past
    /// its first second, or the source's first frame before there is one.
    func cover(for project: LocalProject) async -> UIImage? {
        if let movie = project.exports.last, let image = await frame(LocalStore.file(movie.file, project: project.id), at: min(1.5, movie.duration / 2)) {return image}
        return await image(for: project)
    }
    /// Removes a deleted project's pictures.
    func forget(_ projectID: String) {
        memory.removeAllObjects()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(projectID + "-") {try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))}
    }
    /// Waits for a free decoder; false when the caller was cancelled first.
    private func turn() async -> Bool {
        if Task.isCancelled {return false}
        if running < limit {running += 1; return true}
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation {waiting.append((id, $0))}
        } onCancel: {
            Task {await self.giveUp(id)}
        }
        if granted && Task.isCancelled {done(); return false}
        return granted
    }
    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: {$0.id == id}) else {return}
        waiting.remove(at: index).turn.resume(returning: false)
    }
    private func done() {
        if waiting.isEmpty {running -= 1} else {waiting.removeFirst().turn.resume(returning: true)}
    }
}
