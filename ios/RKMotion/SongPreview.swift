import AVFoundation
import Foundation

/// Plays a YouTube search result straight from YouTube, so the rider can
/// hear a song before adding it. Nothing is saved; one song plays at a time.
@MainActor final class SongPreview: ObservableObject {
    @Published private(set) var playing: String?
    @Published private(set) var loading: String?
    @Published var failure: String?
    private let player = AVPlayer()
    private var task: Task<Void, Never>?
    private var ended: NSObjectProtocol?
    typealias Resolve = (URL) async throws -> URL
    private let resolve: Resolve

    init(resolve: @escaping Resolve = YouTubeMusic.listeningURL) {self.resolve = resolve}

    /// Plays `id`, or stops it when it is already playing or loading.
    func toggle(_ id: String, link: URL) {
        if playing == id || loading == id {stop(); return}
        stop()
        loading = id; failure = nil
        task = Task {
            do {
                let url = try await resolve(link)
                try Task.checkCancellation()
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let item = AVPlayerItem(url: url)
                ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {[weak self] _ in
                    Task {@MainActor in self?.stop()}
                }
                player.replaceCurrentItem(with: item)
                player.play()
                loading = nil; playing = id
            } catch is CancellationError {
            } catch {
                loading = nil
                failure = NSLocalizedString("לא ניתן להשמיע את השיר כרגע.", comment: "A YouTube song could not be played")
            }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        if let ended {NotificationCenter.default.removeObserver(ended)}
        ended = nil; playing = nil; loading = nil
    }
}
