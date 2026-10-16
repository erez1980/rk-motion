import SwiftUI
import AVFoundation

/// Listen to a song and choose the moment the movie starts playing it from.
struct MusicStartView: View {
    @ObservedObject var model: EditorModel
    let song: LocalMusic
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double = 0
    @State private var position: Double = 0
    @State private var playing = false
    @State private var levels: [Double] = []
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var drop: (start: Double, drop: Double, peak: Double)?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note").font(.system(size: 18, weight: .medium)).foregroundStyle(RK.accent)
                            .frame(width: 44, height: 44).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: song.name).font(RK.font(16, 500)).foregroundStyle(RK.ink).lineLimit(2)
                            Text(verbatim: RK.clock(song.duration)).font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                        }
                    }
                    Text("נגנו, ועצרו ברגע שממנו הסרט יתחיל. אפשר גם לגרור על הגל.").font(RK.font(14)).foregroundStyle(RK.soft)
                    wave
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("התחלה בסרט").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint)
                            Text(verbatim: RK.clock(start)).font(RK.font(30, 700, style: .largeTitle)).monospacedDigit().foregroundStyle(RK.accent)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("מיקום הנגינה").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint)
                            Text(verbatim: RK.clock(position)).font(RK.font(18, 500)).monospacedDigit().foregroundStyle(RK.ink)
                        }
                    }
                    HStack(spacing: 22) {
                        Button {skip(-5)} label: {Image(systemName: "gobackward.5")}.buttonStyle(IconButtonStyle()).accessibilityLabel("חמש שניות אחורה")
                        Button(action: toggle) {
                            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 28, weight: .bold)).foregroundStyle(RK.accentInk)
                                .frame(width: 72, height: 72).background(RK.accent, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel(playing ? "עצירה" : "ניגון")
                        Button {skip(5)} label: {Image(systemName: "goforward.5")}.buttonStyle(IconButtonStyle()).accessibilityLabel("חמש שניות קדימה")
                    }
                    .frame(maxWidth: .infinity)
                    .environment(\.layoutDirection, .leftToRight)
                    Button {setStart(position)} label: {
                        Label(String(format: NSLocalizedString("התחלה מהרגע הזה — %@", comment: "Use the playing moment as the song's start"), RK.clock(position)), systemImage: "flag.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(abs(position - start) < 0.5)
                    if let drop {
                        Button {setStart(drop.start)} label: {
                            Label(String(format: NSLocalizedString("הדרופ על השיא — %@", comment: "Start the song so its drop lands on the movie's strongest moment"), RK.clock(drop.start)), systemImage: "sparkles")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(abs(drop.start - start) < 0.1)
                        .accessibilityIdentifier("music.dropStart")
                        Text(verbatim: String(format: NSLocalizedString("הדרופ של השיר ב־%1$@ ייפול על הרגע הכי חזק בסרט, ב־%2$@.", comment: "What the drop start does"), RK.clock(drop.drop), RK.clock(drop.peak)))
                            .font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {Text(verbatim: note).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)}
                }.padding(20)
            }
            .background(RK.bg.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                Button {model.edit.setMusicStart(start, for: song.id); dismiss()} label: {
                    Text(verbatim: String(format: NSLocalizedString("שימוש בשיר מ־%@", comment: "Confirm the song's start"), RK.clock(start)))
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8).background(RK.bg)
            }
            .navigationTitle("מאיפה השיר יתחיל")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement: .cancellationAction) {Button("ביטול") {dismiss()}}}
        }
        .tint(RK.accent)
        .environment(\.layoutDirection, AppLanguage.direction)
        .task {await prepare()}
        .onDisappear(perform: stop)
    }

    private var length: Double {max(1, song.duration)}
    private var used: Double? {model.movieDuration}
    private var note: String? {
        guard let used, used > 0 else {return nil}
        if start + used <= song.duration {
            return String(format: NSLocalizedString("הסרט (%1$@) ישמיע את השיר מ־%2$@ עד %3$@.", comment: "Which part of the song the movie uses"), RK.clock(used), RK.clock(start), RK.clock(start + used))
        }
        return String(format: NSLocalizedString("הסרט (%@) ארוך מהשיר מהנקודה הזאת; אחרי סוף השיר המוזיקה תמשיך.", comment: "The movie outlasts the song"), RK.clock(used))
    }

    /// The song drawn left to right like time, with the part the movie uses lit.
    private var wave: some View {
        GeometryReader {geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .leading) {
                if levels.isEmpty {
                    Capsule().fill(RK.line).frame(height: 4).frame(maxHeight: .infinity)
                } else {
                    HStack(alignment: .center, spacing: 1.5) {
                        ForEach(levels.indices, id: \.self) {index in
                            RoundedRectangle(cornerRadius: 1.5).fill(color(index)).frame(maxWidth: .infinity).frame(height: max(4, levels[index] * 88))
                        }
                    }.frame(maxHeight: .infinity)
                }
                Rectangle().fill(RK.accent).frame(width: 3).offset(x: x(start, width) - 1.5)
                Rectangle().fill(RK.ink).frame(width: 2).offset(x: x(position, width) - 1).opacity(playing || abs(position - start) >= 0.5 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {drag in setStart(drag.location.x / width * length)})
        }
        .frame(height: 96)
        .padding(12)
        .background(RK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement()
        .accessibilityLabel("נקודת ההתחלה בשיר")
        .accessibilityValue(RK.clock(start))
        .accessibilityAdjustableAction {direction in move(direction == .increment ? 1 : -1)}
    }
    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {CGFloat(min(1, max(0, time / length))) * width}
    private func color(_ index: Int) -> Color {
        let time = (Double(index) + 0.5) / Double(levels.count) * length
        let end = start + (used ?? length)
        return time >= start && time <= end ? RK.accent : RK.barIdle
    }

    private func prepare() async {
        guard player == nil, let project = model.project else {return}
        // Playback, so the song is heard with the ringer switched to silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        let file = LocalStore.file(song.file, project: project.id)
        start = min(model.edit.musicStart(for: song.id, first: project.music.first?.id == song.id), max(0, song.duration - 1))
        position = start
        let player = AVPlayer(url: file)
        self.player = player
        await player.seek(to: time(start), toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) {now in
            MainActor.assumeIsolated {
                if player.timeControlStatus != .paused {position = now.seconds.isFinite ? now.seconds : position}
                playing = player.timeControlStatus != .paused
            }
        }
        levels = (try? await LocalEngine.waveform(file)) ?? []
        drop = await model.dropStart(for: song)
        // A song whose start nobody chose yet starts where its drop meets the peak.
        if let drop, model.edit.settings["musicStart:" + song.id] == nil, !(project.music.first?.id == song.id && model.edit.settings["musicStart"].map({$0.string != "0"}) == true) {
            setStart(drop.start)
        }
    }
    private func stop() {
        player?.pause()
        if let observer {player?.removeTimeObserver(observer)}
        observer = nil
    }
    private func toggle() {
        guard let player else {return}
        if playing {player.pause(); playing = false; return}
        if position >= song.duration - 0.25 {position = start}
        player.seek(to: time(position), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); playing = true
    }
    private func move(_ seconds: Double) {setStart(start + seconds)}
    /// Moves playback only; the start changes when the rider says so.
    private func skip(_ seconds: Double) {
        position = min(max(0, position + seconds), max(0, song.duration - 0.25))
        player?.seek(to: time(position), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func setStart(_ value: Double) {
        start = min(max(0, value.isFinite ? value : 0), max(0, song.duration - 1))
        position = start
        player?.seek(to: time(start), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func time(_ seconds: Double) -> CMTime {CMTime(seconds: seconds, preferredTimescale: 600)}
}
