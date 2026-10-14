import SwiftUI
import UIKit
import PhotosUI
import AVKit
import UniformTypeIdentifiers

/// One ride, from the raw video to a movie in Photos, one step at a time.
struct ProjectFlowView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: FlowStep = .video
    @State private var confirmDelete = false
    @State private var showAbout = false
    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: step, reachable: reachable) {step = $0}
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 12)
            content
        }
        .background(RK.bg.ignoresSafeArea())
        .navigationTitle(Text(verbatim: model.project?.name ?? NSLocalizedString("רכיבה חדשה", comment: "New ride title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {ToolbarItem(placement: .topBarTrailing) {menu}}
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {Spacer(); Button("בוצע") {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)}}
        }
        .onAppear {step = model.project?.analyzed == true ? .edit : .video}
        .onChange(of: model.project?.analyzed) {old, new in if new == true && old == false {step = .edit}}
        .onChange(of: model.project?.exports.count) {old, new in if let old, let new, new > old {step = .done}}
        .onChange(of: model.movieURL) {_, movie in if movie == nil && step == .done {step = .export}}
        .onChange(of: model.project?.id) {old, new in if old != nil && new == nil {dismiss()}}
        .confirmationDialog("למחוק את הפרויקט ואת הקבצים שלו מהאייפון?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {Task {await model.reset()}}
        }
        .sheet(isPresented: $showAbout) {NavigationStack {AboutView()}}
    }
    @ViewBuilder private var content: some View {
        if let work = model.work, [.importing, .analyzing, .exporting].contains(work) {
            WorkingStage(model: model, work: work)
        } else {
            switch step {
            case .video: VideoStep(model: model) {step = .edit}
            case .edit: EditStep(model: model) {step = .music}
            case .music: MusicStep(model: model) {step = .export}
            case .export: ExportStep(model: model) {step = .done}
            case .done: DoneStep(model: model) {step = .edit}
            }
        }
    }
    private func reachable(_ target: FlowStep) -> Bool {
        guard !model.busy else {return false}
        switch target {
        case .video: return true
        case .done: return model.movieURL != nil
        default: return model.project?.analyzed == true
        }
    }
    private var menu: some View {
        Menu {
            Button {model.redo()} label: {Label("שחזור שינוי", systemImage: "arrow.uturn.forward")}
                .disabled(!model.redoAvailable || model.busy)
            Button {Task {await model.cleanTemporaryFiles()}} label: {Label("ניקוי קבצים זמניים שנותרו", systemImage: "sparkles")}
                .disabled(model.busy)
            Button {showAbout = true} label: {Label("אודות ועזרה", systemImage: "questionmark.circle")}
            if model.project != nil {
                Section {
                    Button(role: .destructive) {confirmDelete = true} label: {Label("מחיקת הפרויקט מהאייפון", systemImage: "trash")}
                        .disabled(model.busy)
                } header: {
                    Text(verbatim: String(format: NSLocalizedString("נפח הפרויקט: %@", comment: "Project storage size"), ByteCountFormatter.string(fromByteCount: model.projectBytes, countStyle: .file)))
                }
            }
        } label: {Image(systemName: "ellipsis.circle").foregroundStyle(RK.soft)}
        .accessibilityLabel("אפשרויות הפרויקט")
    }
}

/// The pinned area under a step: what to do next.
private struct ActionBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 8) {content}
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
            .background(RK.bg)
    }
}

/// A large choice tile, as for picking where a file comes from.
private struct SourceTile: View {
    let title: LocalizedStringKey
    let symbol: String
    var picked = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(RK.accent)
            Text(title).font(RK.font(15, 500)).foregroundStyle(RK.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 56)
        .background(picked ? RK.accentSoft : RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(picked ? RK.accent : RK.line))
        .contentShape(Rectangle())
    }
}

private struct WorkingStage: View {
    @ObservedObject var model: EditorModel
    let work: Work
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(RK.line, lineWidth: 10)
                Circle().trim(from: 0, to: min(1, max(0.01, model.percent / 100)))
                    .stroke(RK.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: model.percent)
                Text(verbatim: "\(Int(model.percent))%").font(RK.font(36, 700, style: .largeTitle)).monospacedDigit().foregroundStyle(RK.ink)
            }
            .frame(width: 168, height: 168)
            .accessibilityElement().accessibilityLabel("התקדמות העיבוד")
            .accessibilityValue(String(format: NSLocalizedString("%@ אחוז", comment: "Progress percent"), "\(Int(model.percent))"))
            Text(LocalizedStringKey(model.message)).font(RK.font(17, 500)).foregroundStyle(RK.ink).multilineTextAlignment(.center)
            Text("השאירו את האפליקציה פתוחה עד שהפעולה תסתיים.").font(RK.font(14)).foregroundStyle(RK.soft).multilineTextAlignment(.center)
            Text(LocalizedStringKey(model.backgroundDescription)).font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint).multilineTextAlignment(.center)
            Spacer()
            Button(cancelTitle) {model.cancel()}.buttonStyle(SecondaryButtonStyle(height: 56)).disabled(!model.canCancel)
        }.padding(.horizontal, 28).padding(.bottom, 8)
    }
    private var cancelTitle: LocalizedStringKey {
        switch work {case .analyzing: "ביטול הניתוח"; case .exporting: "ביטול הייצוא"; default: "ביטול הפעולה"}
    }
}

// MARK: - Video

private struct VideoStep: View {
    @ObservedObject var model: EditorModel
    let next: () -> Void
    @State private var picked: PhotosPickerItem?
    @State private var showImporter = false
    var body: some View {
        List {
            if let project = model.project {
                HStack(spacing: 12) {
                    Image(systemName: "film").font(.system(size: 20)).foregroundStyle(RK.accent)
                        .frame(width: 48, height: 48).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: project.name).font(RK.font(15, 500)).foregroundStyle(RK.ink).lineLimit(1)
                        Text(verbatim: details(project)).font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                    }
                }.rkCard(padding: 12).rkRow()
            } else {
                Text("בחרו את הסרטון").font(RK.font(22, 700, style: .title2)).foregroundStyle(RK.ink).rkRow(top: 4)
                HStack(spacing: 10) {
                    PhotosPicker(selection: $picked, matching: .videos, preferredItemEncoding: .current) {SourceTile(title: "מהתמונות", symbol: "photo.on.rectangle")}
                    Button {showImporter = true} label: {SourceTile(title: "מהקבצים", symbol: "folder")}
                }.buttonStyle(.plain).disabled(model.busy).rkRow()
            }
            VStack(alignment: .leading, spacing: 8) {
                ToggleRow(title: "הסרטון כבר ערוך", detail: "שומרים אותו שלם ומוסיפים רק מוזיקה", isOn: $model.wholeVideo)
                if model.project?.analyzed == true && model.wholeVideo != model.project?.wholeVideo {
                    Text("הפעולה מחליפה את הקטעים הנוכחיים; אפשר לבטל את השינוי.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                }
            }.rkCard().disabled(model.busy).rkRow()
            Label("הניתוח רץ באייפון. הסרטון לא יוצא מהמכשיר.", systemImage: "lock.fill")
                .font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).rkRow(top: 10)
            if model.busy {ProgressCard(model: model).rkRow()}
            MessageCard(model: model).rkRow()
        }
        .rkScreen()
        .safeAreaInset(edge: .bottom) {
            if let project = model.project {
                ActionBar {
                    if !project.analyzed {Button("ניתוח הסרטון") {model.analyze()}.buttonStyle(PrimaryButtonStyle())}
                    else if model.wholeVideo != project.wholeVideo {Button("החלת מצב הבחירה על הפרויקט") {model.applyWholeVideo()}.buttonStyle(PrimaryButtonStyle())}
                    else {Button("המשך לעריכה", action: next).buttonStyle(PrimaryButtonStyle())}
                }.disabled(model.busy)
            }
        }
        .onChange(of: picked) {_, item in
            guard let item else {return}
            model.importPickedVideo(item); picked = nil
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie]) {result in
            switch result {
            case .success(let source): Task {await model.importVideo(source)}
            case .failure(let error): model.message = error.localizedDescription
            }
        }
    }
    private func details(_ project: LocalProject) -> String {
        var parts: [String] = []
        if project.duration > 0 {parts.append(RK.clock(project.duration))}
        if model.sourceDimensions.width > 0 {parts.append("\(Int(model.sourceDimensions.width))×\(Int(model.sourceDimensions.height))")}
        if model.projectBytes > 0 {parts.append(ByteCountFormatter.string(fromByteCount: model.projectBytes, countStyle: .file))}
        return parts.joined(separator: " · ")
    }
}

// MARK: - Edit

private struct EditStep: View {
    @ObservedObject var model: EditorModel
    let next: () -> Void
    private struct TrimSelection: Identifiable {let id: String}
    @State private var player: AVPlayer?
    @State private var showingEdit = false
    @State private var trimming: TrimSelection?
    @State private var tuning = false
    var body: some View {
        List {
            VStack(spacing: 10) {
                Group {
                    if let player {VideoPlayer(player: player)} else {RK.card}
                }
                .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                HStack(spacing: 0) {
                    viewChoice("המקור", picked: !showingEdit) {showSource()}
                    viewChoice("העריכה", picked: showingEdit) {showEdit()}
                        .disabled(model.busy || model.editValidationMessage != nil)
                }
                .padding(3).background(RK.card, in: Capsule())
            }.rkRow(top: 0)
            if model.work == .previewing {ProgressCard(model: model).rkRow()}
            if let project = model.project, !project.scores.isEmpty {
                ActivityCard(scores: project.scores, duration: project.duration, clips: model.edit.clips, threshold: model.threshold) {tuning = true}
                    .disabled(model.busy).rkRow()
            }
            clipsHeader.rkRow(top: 12)
            ForEach($model.edit.clips) {$clip in
                ClipRow(clip: $clip, canTrim: (model.project?.duration ?? 0) > 0.01) {trimming = TrimSelection(id: clip.id)}
                    .disabled(model.busy).rkRow(top: 4, bottom: 4)
            }
            .onMove {if !model.busy {model.edit.clips.move(fromOffsets: $0, toOffset: $1)}}
            .onDelete {if !model.busy {model.edit.clips.remove(atOffsets: $0)}}
            if model.edit.clips.isEmpty {
                Text("לא זוהו קטעי פעילות. שנו רגישות או הוסיפו קטע ידני.").font(RK.font(14)).foregroundStyle(RK.soft).rkCard().rkRow()
            } else {
                Text("החזיקו וגררו קטע לשינוי הסדר, החליקו למחיקה.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint).rkRow()
            }
            MessageCard(model: model).rkRow()
        }
        .rkScreen()
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                if let problem = model.editValidationMessage {
                    Text(LocalizedStringKey(problem)).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.danger).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button {model.undo()} label: {Image(systemName: "arrow.uturn.backward")}
                        .buttonStyle(IconButtonStyle()).disabled(!model.undoAvailable || model.busy).accessibilityLabel("ביטול שינוי")
                    Button("המשך למוזיקה", action: next).buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                }
            }
        }
        .sheet(item: $trimming) {selection in
            if let index = model.edit.clips.firstIndex(where: {$0.id == selection.id}),
               let source = model.sourceURL, let duration = model.project?.duration, duration > 0.01 {
                ClipTrimView(clip: $model.edit.clips[index], source: source, duration: duration)
            }
        }
        .sheet(isPresented: $tuning) {SensitivitySheet(model: model).presentationDetents([.height(320)])}
        .onAppear {
            if let item = model.previewItem {player = AVPlayer(playerItem: item); showingEdit = true}
            else if player == nil {player = model.sourceURL.map(AVPlayer.init(url:))}
        }
        .onChange(of: model.previewItem) {_, item in
            if let item {player?.pause(); player = AVPlayer(playerItem: item); showingEdit = true; player?.play()}
            else if showingEdit {showSource()}
        }
        .onDisappear {player?.pause()}
    }
    private func viewChoice(_ title: LocalizedStringKey, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(RK.font(14, picked ? 500 : 400)).foregroundStyle(picked ? RK.accentInk : RK.soft)
                .frame(maxWidth: .infinity, minHeight: 36).background(picked ? RK.accent : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(picked ? .isSelected : [])
    }
    private func showSource() {
        player?.pause(); showingEdit = false
        player = model.sourceURL.map(AVPlayer.init(url:))
    }
    private func showEdit() {
        if let item = model.previewItem {
            player?.pause(); player = AVPlayer(playerItem: item); showingEdit = true
        } else {model.preview()}
    }
    private var clipsHeader: some View {
        let selected = model.selectedClips
        return HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("קטעים").font(RK.font(17, 500, style: .headline)).foregroundStyle(RK.ink)
                Text(verbatim: String(format: NSLocalizedString("%@ מתוך %@ · %@", comment: "Selected clips of all, and their length"), "\(selected.count)", "\(model.edit.clips.count)", RK.clock(selected.reduce(0) {$0 + $1.duration})))
                    .font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
            }
            Spacer()
            Button(action: addClip) {
                Label("הוספה", systemImage: "plus").font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.accentSoftInk)
                    .padding(.horizontal, 12).frame(minHeight: 36).background(RK.accentSoft, in: Capsule())
            }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel("הוספת קטע ידני")
        }
    }
    private func addClip() {
        // Edited-preview time is not a timestamp in the original.
        let playhead = showingEdit ? 0 : (player?.currentTime().seconds ?? 0)
        let duration = model.project?.duration ?? 0
        let start = min(playhead.isFinite ? max(0, playhead) : 0, max(0, duration - 1))
        var clip = Clip(start: max(0, start), end: min(duration, start + 5)); clip.manual = true
        model.edit.clips.append(clip)
    }
}

/// The ride's activity over time, with the chosen moments lit up.
private struct ActivityCard: View {
    let scores: [Double]
    let duration: Double
    let clips: [Clip]
    let threshold: Double
    let tune: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("פעילות לאורך הרכיבה").font(RK.font(14, 500)).foregroundStyle(RK.ink)
                Spacer()
                Button(action: tune) {
                    Text(verbatim: String(format: NSLocalizedString("רגישות · %@", comment: "Detection sensitivity chip"), level))
                        .font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                        .padding(.horizontal, 10).frame(minHeight: 32).overlay(Capsule().stroke(RK.line))
                }.buttonStyle(.plain)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) {_, bar in
                    RoundedRectangle(cornerRadius: 2).fill(bar.color).frame(maxWidth: .infinity).frame(height: 6 + bar.value * 46)
                }
            }
            .frame(height: 52, alignment: .bottom)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement().accessibilityLabel("גרף הפעילות לאורך הרכיבה")
            HStack {
                ForEach(0..<4) {i in
                    Text(verbatim: RK.clock(duration * Double(i) / 3))
                    if i < 3 {Spacer()}
                }
            }.font(RK.font(11, 400, style: .caption2)).monospacedDigit().foregroundStyle(RK.faint)
            .environment(\.layoutDirection, .leftToRight)
        }
        .rkCard()
    }
    private var level: String {
        threshold <= 0.45 ? NSLocalizedString("גבוהה", comment: "High sensitivity")
            : threshold <= 0.65 ? NSLocalizedString("בינונית", comment: "Medium sensitivity")
            : NSLocalizedString("נמוכה", comment: "Low sensitivity")
    }
    private var bars: [(value: Double, color: Color)] {
        guard !scores.isEmpty else {return []}
        let count = min(52, scores.count)
        return (0..<count).map {i in
            let lower = i * scores.count / count, upper = max(lower + 1, (i + 1) * scores.count / count)
            let value = scores[lower..<min(upper, scores.count)].max() ?? 0
            let time = (Double(i) + 0.5) / Double(count) * duration
            let clip = clips.first {time >= $0.start && time <= $0.end}
            let color = clip == nil ? RK.barIdle : clip?.selected == false ? RK.barSkipped : RK.accent
            return (value.isFinite ? min(1, max(0, value)) : 0, color)
        }
    }
}

private struct ClipRow: View {
    @Binding var clip: Clip
    let canTrim: Bool
    let trim: () -> Void
    var body: some View {
        let selected = clip.selected != false
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 15)).foregroundStyle(RK.faint).accessibilityHidden(true)
            Button {clip.selected = !selected} label: {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(selected ? RK.accentInk : .clear)
                    .frame(width: 28, height: 28)
                    .background(selected ? RK.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.clear : RK.faint, lineWidth: 2))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selected ? "הסרת הקטע מהסרט" : "הוספת הקטע לסרט")
            VStack(alignment: .leading, spacing: 2) {
                // Isolated, so "0:36–1:12" keeps its order inside Hebrew text.
                Text(verbatim: "\u{2066}\(RK.clock(clip.start))–\(RK.clock(clip.end))\u{2069}").font(RK.font(15, 500)).monospacedDigit().foregroundStyle(RK.ink)
                Text(verbatim: RK.seconds(clip.duration)).font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            }
            Spacer(minLength: 0)
            if let score = clip.score {Pill(text: "\(Int(score * 100))%")}
            else if clip.manual == true {Pill(text: NSLocalizedString("ידני", comment: "Manually added clip"), fill: RK.raised, ink: RK.soft)}
            if canTrim {
                Button(action: trim) {
                    Image(systemName: "scissors").font(.system(size: 16, weight: .medium)).foregroundStyle(RK.soft)
                        .frame(width: 40, height: 40).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: NSLocalizedString("תצוגה וחיתוך קטע שמתחיל ב־%@ שניות", comment: "Trim button label"), "\(Int(clip.start.isFinite ? clip.start : 0))"))
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(selected ? 1 : 0.55)
    }
}

private struct SensitivitySheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("רגישות זיהוי הפעילות").font(RK.font(19, 700, style: .title3)).foregroundStyle(RK.ink)
            // Higher sensitivity is a lower activity threshold, so more clips.
            Slider(value: Binding(get: {1.15 - model.threshold}, set: {model.threshold = 1.15 - $0}), in: 0.25...0.9, step: 0.05) {
                Text("רגישות זיהוי הפעילות")
            } minimumValueLabel: {
                Text("פחות קטעים").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            } maximumValueLabel: {
                Text("יותר קטעים").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            }.tint(RK.accent)
            Text("הצעות הפעילות יוחלפו; ניתן לבטל את השינוי.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            Spacer(minLength: 0)
            Button("הפקת הצעות מחדש") {model.retune(); dismiss()}.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
        }
        .padding(20)
        .presentationBackground(RK.bg)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

// MARK: - Music

private struct MusicStep: View {
    @ObservedObject var model: EditorModel
    let next: () -> Void
    @State private var showImporter = false
    @State private var showYouTube = false
    @State private var query = ""
    @State private var results: [YouTubeSearch.Result] = []
    @State private var searching = false
    @State private var searchNote: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var fetching: String?
    @State private var added: Set<String> = []
    @State private var choosing: LocalMusic?
    var body: some View {
        List {
            HStack(spacing: 10) {
                Button {showImporter = true} label: {SourceTile(title: "מהקבצים", symbol: "folder")}
                Button {showYouTube.toggle()} label: {SourceTile(title: "מ־YouTube", symbol: "play.rectangle.fill", picked: showYouTube)}
            }.buttonStyle(.plain).disabled(model.busy).rkRow(top: 0)
            if showYouTube || model.work == .downloading {
                youTube.rkRow()
                ForEach(results) {result in resultRow(result).rkRow(top: 4, bottom: 4)}
            } else if model.busy {ProgressCard(model: model).rkRow()}
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("השירים בפרויקט").font(RK.font(17, 500, style: .headline)).foregroundStyle(RK.ink)
                Text(verbatim: "\(songs.count)").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            }.rkRow(top: 12)
            if songs.isEmpty {
                Text("עוד אין מוזיקה בפרויקט. הוסיפו שיר מהקבצים או מ־YouTube.").font(RK.font(14)).foregroundStyle(RK.soft).rkCard().rkRow()
            }
            ForEach(songs) {song in songRow(song).rkRow(top: 4, bottom: 4)}
            VStack(alignment: .leading, spacing: 14) {
                if !songs.isEmpty {
                    ToggleRow(title: "שימוש במוזיקה", isOn: flag("useMusic", fallback: true))
                    ChoiceGroup(title: "עוצמת המוזיקה", options: [(NSLocalizedString("רקע", comment: "Quiet music"), "0.35"), (NSLocalizedString("מאוזן", comment: "Balanced music"), "0.65"), (NSLocalizedString("חזק", comment: "Loud music"), "1")], selection: setting("musicVolume", fallback: "0.65"))
                }
                ToggleRow(title: "השתקת שמע הרכיבה", isOn: flag("muteOriginal", fallback: false))
            }.rkCard().disabled(model.busy).rkRow(top: 12)
            MessageCard(model: model).rkRow()
        }
        .rkScreen()
        .safeAreaInset(edge: .bottom) {ActionBar {Button("המשך לייצוא", action: next).buttonStyle(PrimaryButtonStyle()).disabled(model.busy)}}
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) {result in
            switch result {
            case .success(let source): Task {await model.importMusic(source)}
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        // A new song is offered for listening at once, to choose where it starts.
        .onChange(of: model.addedSong) {_, id in
            guard let id else {return}
            if let fetching {added.insert(fetching)}
            fetching = nil; model.addedSong = nil
            if YouTubeMusic.link(in: query) != nil {query = ""}
            choosing = songs.first {$0.id == id}
        }
        .onChange(of: model.busy) {_, busy in if !busy && model.addedSong == nil {fetching = nil}}
        .sheet(item: $choosing) {song in MusicStartView(model: model, song: song)}
        .onDisappear {searchTask?.cancel()}
    }
    private var songs: [LocalMusic] {model.project?.music ?? []}
    private var isLink: Bool {YouTubeMusic.link(in: query) != nil}
    private var youTube: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("חיפוש שיר לפי שם, או הדבקת קישור").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: isLink ? "link" : "magnifyingglass").foregroundStyle(RK.faint)
                    TextField("שם השיר והאמן", text: $query)
                        .autocorrectionDisabled().submitLabel(isLink ? .go : .search)
                        .onSubmit(go)
                        .font(RK.font(15)).foregroundStyle(RK.ink)
                        .accessibilityLabel("חיפוש שיר ב־YouTube")
                    if !query.isEmpty {
                        Button {query = ""; results = []; searchNote = nil} label: {Image(systemName: "xmark.circle.fill").foregroundStyle(RK.faint)}
                            .buttonStyle(.plain).accessibilityLabel("ניקוי החיפוש")
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(RK.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RK.line))
                PasteButton(payloadType: String.self) {strings in query = strings.first ?? query}
                    .labelStyle(.iconOnly).buttonBorderShape(.roundedRectangle(radius: 12)).tint(RK.raised).foregroundStyle(RK.ink)
            }.disabled(model.busy)
            if model.work == .downloading {
                ProgressView(value: min(100, max(0, model.percent)), total: 100).tint(RK.accent)
                HStack {
                    Text(LocalizedStringKey(model.message)).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.ink)
                    Spacer()
                    Text(verbatim: "\(Int(model.percent))%").font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                }
                Button("ביטול ההורדה") {model.cancel()}.font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.soft).buttonStyle(.plain)
            } else {
                Button(action: go) {
                    if searching {ProgressView().tint(RK.accentInk)}
                    else {Label(isLink ? LocalizedStringKey("הורדת השמע") : LocalizedStringKey("חיפוש"), systemImage: isLink ? "arrow.down" : "magnifyingglass")}
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.busy || searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let searchNote {Text(verbatim: searchNote).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)}
                else {Text("השמע יורד ישירות לאייפון.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint)}
            }
        }.rkCard()
    }
    private func go() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.busy else {return}
        if isLink {model.importYouTube(text); return}
        searchTask?.cancel(); searching = true; searchNote = nil
        searchTask = Task {
            do {
                let found = try await YouTubeSearch.search(text)
                try Task.checkCancellation()
                results = found
                if found.isEmpty {searchNote = NSLocalizedString("לא נמצאו תוצאות. נסו שם אחר.", comment: "YouTube search found nothing")}
            } catch is CancellationError {return}
            catch {searchNote = error.localizedDescription}
            searching = false
        }
    }
    private func resultRow(_ result: YouTubeSearch.Result) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.thumbnail) {image in image.resizable().scaledToFill()} placeholder: {RK.raised}
                .frame(width: 72, height: 48).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.title).font(RK.font(14, 500)).foregroundStyle(RK.ink).lineLimit(2)
                Text(verbatim: [result.channel, RK.clock(result.duration)].filter {!$0.isEmpty}.joined(separator: " · "))
                    .font(RK.font(12, 400, style: .caption1)).monospacedDigit().foregroundStyle(RK.soft).lineLimit(1)
            }
            Spacer(minLength: 0)
            if fetching == result.id {
                ProgressView().tint(RK.accent).frame(width: 40, height: 40)
            } else if added.contains(result.id) {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(RK.accent).frame(width: 40, height: 40)
                    .accessibilityLabel("השיר נוסף לפרויקט")
            } else {
                Button {fetching = result.id; model.importYouTube(link: result.link)} label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(RK.accentSoftInk)
                        .frame(width: 40, height: 40).background(RK.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel(String(format: NSLocalizedString("הוספת %@ לפרויקט", comment: "Add a found song"), result.title))
            }
        }
        .padding(8).background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func songRow(_ song: LocalMusic) -> some View {
        let start = model.edit.musicStart(for: song.id, first: songs.first?.id == song.id)
        return HStack(spacing: 12) {
            Button {choosing = song} label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform").font(.system(size: 18, weight: .medium)).foregroundStyle(RK.accent)
                        .frame(width: 40, height: 40).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: song.name).font(RK.font(15, 500)).foregroundStyle(RK.ink).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: RK.clock(song.duration) + " · " + String(format: NSLocalizedString("מתחיל ב־%@", comment: "Where a song starts"), RK.clock(start)))
                            .font(RK.font(12, 400, style: .caption1)).monospacedDigit().foregroundStyle(RK.soft)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(RK.faint)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("האזנה לשיר ובחירת המקום שממנו יתחיל")
            Button {Task {await model.removeMusic(song.id)}} label: {
                Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(RK.faint).frame(width: 40, height: 40).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel("הסרת השיר")
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.edit.settings[key] = .text($0)})
    }
    private func flag(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: {model.edit.settings[key]?.bool ?? fallback}, set: {model.edit.settings[key] = .flag($0)})
    }
}

// MARK: - Export

private struct ExportStep: View {
    @ObservedObject var model: EditorModel
    let showMovie: () -> Void
    var body: some View {
        List {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.expectedDuration.map(RK.clock) ?? "–").font(RK.font(34, 700, style: .largeTitle)).monospacedDigit().foregroundStyle(RK.ink)
                    Text("אורך הסרט").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                }
                Rectangle().fill(RK.line).frame(width: 1, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: contents).font(RK.font(14, 500)).foregroundStyle(RK.ink).lineLimit(2)
                    Text(verbatim: model.expectedFormat).font(RK.font(12, 400, style: .caption1)).monospacedDigit().foregroundStyle(RK.soft)
                }
                Spacer(minLength: 0)
            }.rkCard(padding: 16).rkRow(top: 0)
            Group {
                ChoiceGroup(title: "מסגרת", options: [(NSLocalizedString("מקור", comment: "Source framing"), "source"), (NSLocalizedString("סטורי 9:16", comment: "Story framing"), "9:16")], selection: setting("aspect", fallback: "source"))
                ChoiceGroup(title: "מהירות", options: ["1", "1.25", "1.5", "2"].map {($0 + "×", $0)}, selection: setting("speed", fallback: "1"))
                ChoiceGroup(title: "מעבר בין קטעים", options: [(NSLocalizedString("חיתוך", comment: "Cut transition"), "cut"), (NSLocalizedString("המסה", comment: "Dissolve transition"), "dissolve")], selection: setting("transition", fallback: "cut"))
                if model.edit.settings["transition"]?.string == "dissolve" {
                    ChoiceGroup(title: "משך המעבר", options: ["0.3", "0.5", "1"].map {(String(format: NSLocalizedString("%@ שניות", comment: "Seconds value"), $0), $0)}, selection: setting("transitionDuration", fallback: "0.5"))
                }
                ChoiceGroup(title: "איכות", options: [("1080p", "1080"), ("720p", "720"), (NSLocalizedString("רזולוציית מקור", comment: "Original resolution"), "original"), ("WhatsApp", "whatsapp")], selection: setting("quality", fallback: "1080"))
            }.disabled(model.busy).rkRow()
            Text("כל הייצואים הם SDR ב־30fps. רזולוציית מקור אינה שימור HDR או ייצוא ללא אובדן.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint).rkRow()
            if model.movieURL != nil {
                Button(action: showMovie) {Label("לסרט האחרון שנוצר", systemImage: "play.rectangle")}
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.busy).rkRow()
            }
            if model.busy {ProgressCard(model: model).rkRow()}
            MessageCard(model: model).rkRow()
        }
        .rkScreen()
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                if let problem = model.editValidationMessage {
                    Text(LocalizedStringKey(problem)).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.danger).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {model.exportMovie()} label: {Label("ייצוא הסרט", systemImage: "film.stack")}
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy || model.selectedClips.isEmpty || model.editValidationMessage != nil)
            }
        }
    }
    private var contents: String {
        let clips = String(format: NSLocalizedString("%@ קטעים", comment: "Clip count"), "\(model.selectedClips.count)")
        let songs = model.project?.music ?? []
        guard model.edit.settings["useMusic"]?.bool != false, let first = songs.first else {return clips + " · " + NSLocalizedString("ללא מוזיקה", comment: "No music in the movie")}
        return clips + " · " + (songs.count == 1 ? first.name : String(format: NSLocalizedString("%@ שירים", comment: "Song count"), "\(songs.count)"))
    }
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.edit.settings[key] = .text($0)})
    }
}

// MARK: - Done

private struct DoneStep: View {
    @ObservedObject var model: EditorModel
    let backToEdit: () -> Void
    @State private var player: AVPlayer?
    var body: some View {
        List {
            HStack(spacing: 14) {
                Image(systemName: "checkmark").font(.system(size: 22, weight: .heavy)).foregroundStyle(RK.accentInk)
                    .frame(width: 52, height: 52).background(RK.accent, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("הסרט מוכן").font(RK.font(24, 700, style: .title2)).foregroundStyle(RK.ink)
                    if let current {
                        Text(verbatim: RK.clock(current.duration) + " · " + current.created.formatted(date: .abbreviated, time: .shortened))
                            .font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
                    }
                }
            }.rkRow(top: 0)
            Group {
                if let player {VideoPlayer(player: player)} else {RK.card}
            }
            .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).rkRow()
            if let movie = model.movieURL {
                Button {Task {await model.saveToPhotos(movie)}} label: {Label("שמירה בתמונות", systemImage: "square.and.arrow.down")}
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.busy).rkRow()
                HStack(spacing: 10) {
                    ShareLink(item: movie) {Label("שיתוף", systemImage: "square.and.arrow.up")}.buttonStyle(SecondaryButtonStyle())
                    Button(action: backToEdit) {Label("חזרה לעריכה", systemImage: "slider.horizontal.3")}.buttonStyle(SecondaryButtonStyle())
                }.disabled(model.busy).rkRow()
                if let current {
                    Button(role: .destructive) {Task {await model.deleteExport(current)}} label: {Label("מחיקת הסרט", systemImage: "trash")}
                        .buttonStyle(SecondaryButtonStyle()).disabled(model.busy).rkRow()
                }
            }
            if model.busy {ProgressCard(model: model).rkRow()}
            MessageCard(model: model).rkRow()
            if !earlier.isEmpty {
                Text("סרטים קודמים בפרויקט").font(RK.font(15, 500)).foregroundStyle(RK.soft).rkRow(top: 14)
                ForEach(earlier) {result in
                    Button {play(result)} label: {
                        HStack(spacing: 12) {
                            Image(systemName: "film").foregroundStyle(RK.faint).frame(width: 40, height: 40).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: NSLocalizedString("סרט מ־", comment: "Movie made on date prefix") + result.created.formatted(date: .abbreviated, time: .shortened))
                                    .font(RK.font(15, 500)).foregroundStyle(RK.ink)
                                Text(verbatim: RK.clock(result.duration)).font(RK.font(12, 400, style: .caption1)).monospacedDigit().foregroundStyle(RK.soft)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").foregroundStyle(RK.accent).frame(width: 40, height: 40)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.busy).rkRow(top: 4, bottom: 4)
                    .swipeActions {
                        Button("מחיקת הסרט", role: .destructive) {Task {await model.deleteExport(result)}}.disabled(model.busy)
                    }
                }
                Text("מחיקת סרט שנוצר אינה מוחקת את המקור או את העריכה. עותקים שנשמרו בתמונות אינם נמחקים.")
                    .font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint).rkRow()
            }
            Text(AppVersion.line).font(RK.font(12, 400, style: .caption2)).monospacedDigit().foregroundStyle(RK.faint)
                .frame(maxWidth: .infinity).rkRow(top: 16)
        }
        .rkScreen()
        .onAppear {player = model.movieURL.map(AVPlayer.init(url:))}
        .onChange(of: model.movieURL) {_, movie in player?.pause(); player = movie.map(AVPlayer.init(url:))}
        .onDisappear {player?.pause()}
    }
    private var current: LocalExport? {model.project?.exports.first {$0.file == model.movieURL?.lastPathComponent}}
    private var earlier: [LocalExport] {(model.project?.exports ?? []).filter {$0.file != model.movieURL?.lastPathComponent}.reversed()}
    private func play(_ result: LocalExport) {
        guard let project = model.project else {return}
        model.movieURL = LocalStore.file(result.file, project: project.id)
    }
}
