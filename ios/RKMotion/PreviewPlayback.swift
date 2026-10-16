import AVFoundation
import Combine

/// A prepared edit that can be played. It hands out a new AVPlayerItem for
/// every player that shows it, because AVFoundation ends the app with an
/// exception when one item is put on a second player.
struct PreviewEdit: Equatable {
    let id = UUID()
    let composition: AVComposition
    let video: AVVideoComposition
    let audio: AVAudioMix
    /// GoPro ride readings to show over the edit, twice a second of movie.
    var overlay: [Telemetry.Frame] = []
    func makeItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = video; item.audioMix = audio
        return item
    }
    static func == (lhs: PreviewEdit, rhs: PreviewEdit) -> Bool {lhs.id == rhs.id}
}

/// The edit step's one player, switched between the source and the edit.
/// It owns every item it plays and never replaces itself, so tapping either
/// choice again, or coming back to the step, cannot hand an item to a
/// second player.
@MainActor final class PreviewPlayback: ObservableObject {
    /// `joined` is a project's several videos shown as its source.
    enum Showing: Equatable {case nothing, source(URL), joined(UUID), edit(UUID)}
    let player = AVPlayer()
    @Published private(set) var showing: Showing = .nothing
    var showingEdit: Bool {if case .edit = showing {return true}; return false}

    func showSource(_ url: URL?) {
        guard let url else {player.pause(); player.replaceCurrentItem(with: nil); showing = .nothing; return}
        guard showing != .source(url) else {return}
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        showing = .source(url)
    }
    /// Shows several joined videos as the source.
    func showSource(_ joined: PreviewEdit) {
        guard showing != .joined(joined.id) else {return}
        player.pause()
        player.replaceCurrentItem(with: joined.makeItem())
        showing = .joined(joined.id)
    }
    /// Shows the edit; asking again for the same edit leaves playback alone.
    func showEdit(_ preview: PreviewEdit, play: Bool = false) {
        if showing != .edit(preview.id) {
            player.pause()
            player.replaceCurrentItem(with: preview.makeItem())
            showing = .edit(preview.id)
        }
        if play {player.play()}
    }
    func pause() {player.pause()}
}
