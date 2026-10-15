import AVFoundation
import Combine
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
    private var watching: AnyCancellable?
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
                // The song counts as playing only once AVFoundation can play
                // it: a refused or broken stream fails here, after the item
                // was made, and must not leave a stop button over silence.
                watching = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink {[weak self] status in
                    guard let self, self.loading == id || self.playing == id else {return}
                    switch status {
                    case .readyToPlay: self.loading = nil; self.playing = id
                    case .failed: self.fail()
                    default: break
                    }
                }
                player.replaceCurrentItem(with: item)
                player.play()
            } catch is CancellationError {
            } catch {
                fail()
            }
        }
    }
    private func fail() {
        stop()
        failure = NSLocalizedString("לא ניתן להשמיע את השיר כרגע.", comment: "A YouTube song could not be played")
    }
    func stop() {
        task?.cancel(); task = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        if let ended {NotificationCenter.default.removeObserver(ended)}
        watching = nil; ended = nil; playing = nil; loading = nil
    }
}
