import SwiftUI
import AVKit
import UIKit

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
    @State private var strip: [UIImage?] = Array(repeating: nil, count: 10)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let player {VideoPlayer(player: player)} else {RK.card}
                    }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    filmstrip
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
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: {clip.slowAt != nil}, set: {on in clip.slowAt = on ? slowPoint : nil})) {
                            Label("הילוך איטי בקטע הזה", systemImage: "tortoise").font(RK.font(15, 500)).foregroundStyle(RK.ink)
                        }.tint(RK.accent).accessibilityIdentifier("trim.slow")
                        if let slowAt = clip.slowAt {
                            Text(String(format: NSLocalizedString("ההאטה מתחילה ב־%@ שניות", comment: "Where the clip's slow motion starts"), fixed(slowAt)))
                                .font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                            Button {clip.slowAt = slowPoint} label: {Label("להאט מהנקודה שמוצגת עכשיו", systemImage: "scope")}
                                .buttonStyle(SecondaryButtonStyle())
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
                for index in strip.indices {
                    strip[index] = await Thumbnails.shared.frame(source, at: (Double(index) + 0.5) / Double(strip.count) * duration)
                }
            }
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
    /// The clip's whole video as frames, the chosen part lit; dragging moves
    /// whichever edge is nearer.
    private var filmstrip: some View {
        GeometryReader {geometry in
            let width = max(1, geometry.size.width)
            let x = {(time: Double) in CGFloat((time - lower) / max(duration, 0.01)) * width}
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(strip.indices, id: \.self) {index in
                        Group {
                            if let image = strip[index] {Image(uiImage: image).resizable().scaledToFill()} else {RK.raised}
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                }
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, x(clip.start)))
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, width - x(clip.end))).offset(x: x(clip.end))
                RoundedRectangle(cornerRadius: 6).stroke(RK.accent, lineWidth: 3)
                    .frame(width: max(6, x(clip.end) - x(clip.start))).offset(x: x(clip.start))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {drag in
                let time = min(upper, max(lower, lower + Double(drag.location.x / width) * duration))
                if abs(time - clip.start) <= abs(time - clip.end) {clip.start = min(time, clip.end - 0.1)}
                else {clip.end = max(time, clip.start + 0.1)}
            })
        }
        .frame(height: 56)
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
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
    /// The moment on screen in the player, inside the clip, as a timeline second.
    private var slowPoint: Double {
        let shown = (player?.currentTime().seconds ?? 0) + offset
        guard shown.isFinite, shown > clip.start, shown < clip.end else {return clip.start}
        return shown
    }
    private func play() {
        guard let player else {return}
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.end - offset, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: clip.start - offset, preferredTimescale: 600)) {finished in
            if finished {player.play()}
        }
    }
}
