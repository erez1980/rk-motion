import SwiftUI
import AVKit

struct ClipTrimView: View {
    @Binding var clip: Clip
    let source: URL
    let duration: Double
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            Form {
                if let player {VideoPlayer(player: player).frame(height: 220)}
                Section("חיתוך הקטע") {
                    Text("התחלה: \(clip.start, specifier: "%.2f") שניות")
                    Slider(value: $clip.start, in: 0...max(0.01, min(duration, clip.end) - 0.01), step: 0.01)
                        .accessibilityLabel("תחילת הקטע בשניות")
                    Text("סיום: \(clip.end, specifier: "%.2f") שניות")
                    Slider(value: $clip.end, in: min(duration - 0.01, max(0, clip.start) + 0.01)...duration, step: 0.01)
                        .accessibilityLabel("סיום הקטע בשניות")
                    Button("ניגון הקטע שנבחר") {play()}
                    Text("משך הקטע: \(max(0, clip.end - clip.start), specifier: "%.2f") שניות")
                }
            }.navigationTitle("חיתוך קטע")
             .toolbar {Button("סיום") {player?.pause(); dismiss()}}
             .task {
                 clip.start = min(max(0, clip.start), duration - 0.01)
                 clip.end = min(duration, max(clip.start + 0.01, clip.end))
                 player = AVPlayer(url: source)
                 player?.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600))
             }
             .onDisappear {player?.pause()}
        }
    }
    private func play() {
        guard let player else {return}
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.end, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600)) {finished in
            if finished {player.play()}
        }
    }
}
