import SwiftUI
import AVKit

struct ClipTrimView: View {
    @Binding var clip: Clip
    /// The clip's video, which begins `offset` seconds into the project's
    /// timeline and runs `duration` seconds. The clip's times are the timeline's.
    let source: URL
    var offset: Double = 0
    let duration: Double
    private var lower: Double {offset}
    private var upper: Double {offset + duration}
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let player {VideoPlayer(player: player)} else {RK.card}
                    }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(format: NSLocalizedString("התחלה: %@ שניות", comment: "Clip start readout"), fixed(clip.start)))
                            .font(RK.font(15, 500)).monospacedDigit().foregroundStyle(RK.ink)
                        Slider(value: $clip.start, in: lower...max(lower + 0.01, min(upper, clip.end) - 0.01), step: 0.01).tint(RK.accent)
                            .accessibilityLabel("תחילת הקטע בשניות")
                        Text(String(format: NSLocalizedString("סיום: %@ שניות", comment: "Clip end readout"), fixed(clip.end)))
                            .font(RK.font(15, 500)).monospacedDigit().foregroundStyle(RK.ink)
                        Slider(value: $clip.end, in: min(upper - 0.01, max(lower, clip.start) + 0.01)...upper, step: 0.01).tint(RK.accent)
                            .accessibilityLabel("סיום הקטע בשניות")
                        Text(String(format: NSLocalizedString("משך הקטע: %@ שניות", comment: "Clip length readout"), fixed(max(0, clip.end - clip.start))))
                            .font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                    }.rkCard()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("הזנת זמנים מדויקת").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                        HStack(spacing: 10) {
                            field("התחלה", value: $clip.start, label: "תחילת הקטע בשניות")
                            field("סיום", value: $clip.end, label: "סיום הקטע בשניות")
                        }
                    }.rkCard()
                    Button {play()} label: {Label("ניגון הקטע שנבחר", systemImage: "play.fill")}.buttonStyle(PrimaryButtonStyle())
                }.padding(20)
            }
            .background(RK.bg.ignoresSafeArea())
            .navigationTitle("חיתוך קטע")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {Button("בוצע") {player?.pause(); dismiss()}.font(RK.font(17, 500))}
            .task {
                clip.start = min(max(lower, clip.start), upper - 0.01)
                clip.end = min(upper, max(clip.start + 0.01, clip.end))
                player = AVPlayer(url: source)
                player?.seek(to: CMTime(seconds: clip.start - offset, preferredTimescale: 600))
            }
            .onDisappear {player?.pause()}
        }
        .tint(RK.accent)
        .environment(\.layoutDirection, AppLanguage.direction)
    }
    private func field(_ title: LocalizedStringKey, value: Binding<Double>, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(title).font(RK.font(14)).foregroundStyle(RK.soft)
            TextField("שניות", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad).multilineTextAlignment(.center).font(RK.font(15)).monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RK.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(label)
        }.frame(maxWidth: .infinity)
    }
    // Formatting the number apart from the sentence keeps the catalog key
    // stable, instead of depending on how SwiftUI spells an interpolation.
    private func fixed(_ value: Double) -> String {String(format: "%.2f", value)}
    private func play() {
        guard let player else {return}
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.end - offset, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: clip.start - offset, preferredTimescale: 600)) {finished in
            if finished {player.play()}
        }
    }
}
