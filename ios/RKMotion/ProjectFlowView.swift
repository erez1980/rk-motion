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
    @State private var placed = false
    @State private var revealing = false
    @State private var renaming = false
    @State private var newName = ""
    var body: some View {
        VStack(spacing: 0) {
            StepBar(current: step, reachable: reachable) {step = $0}
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 12)
            content
        }
        .background(RK.bg.ignoresSafeArea())
        .navigationTitle(Text(verbatim: model.project?.name ?? NSLocalizedString("סרטון חדש", comment: "New project title")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.project?.analyzed == true {
                    Button {model.undo()} label: {Image(systemName: "arrow.uturn.backward")}
                        .disabled(!model.undoAvailable || model.busy).accessibilityLabel("ביטול שינוי")
                    Button {model.redo()} label: {Image(systemName: "arrow.uturn.forward")}
                        .disabled(!model.redoAvailable || model.busy).accessibilityLabel("שחזור שינוי")
                }
                menu
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {Spacer(); Button("בוצע") {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)}}
        }
        // Only the first appearance picks the step: SwiftUI can call onAppear
        // again while the screen stays up, which threw the rider back to Edit.
        .onAppear {
            guard !placed else {return}
            placed = true; step = model.project?.analyzed == true ? .edit : .video
        }
        .onChange(of: model.project?.analyzed) {old, new in
            if new == true && old == false {step = .edit; revealing = model.project?.reading != nil && !Self.underUITest}
        }
        .onChange(of: model.project?.exports.count) {old, new in if let old, let new, new > old {step = .done}}
        .onChange(of: model.movieURL) {_, movie in if movie == nil && step == .done {step = .export}}
        .onChange(of: model.project?.id) {old, new in if old != nil && new == nil {dismiss()}}
        .confirmationDialog("למחוק את הפרויקט ואת הקבצים שלו מהאייפון?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("מחיקה", role: .destructive) {Task {await model.reset()}}
        }
        .sheet(isPresented: $showAbout) {NavigationStack {AboutView(clean: {await model.cleanTemporaryFiles()})}}
        .sheet(isPresented: $revealing) {
            RevealSheet(model: model, quick: {
                revealing = false; step = model.project?.music.isEmpty == false ? .export : .music
            }, control: {revealing = false; step = .edit})
            .presentationDetents([.large]).interactiveDismissDisabled(model.busy)
        }
        .alert("שם הפרויקט", isPresented: $renaming) {
            TextField("שם הפרויקט", text: $newName)
            Button("שמירה") {model.rename(newName)}
            Button("ביטול", role: .cancel) {}
        }
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
    /// UI tests drive the edit step straight after the scan.
    private static var underUITest: Bool {
        #if DEBUG
        UITestFixture.requested
        #else
        false
        #endif
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
            if model.project != nil {
                Button {newName = model.project?.name ?? ""; renaming = true} label: {Label("שינוי שם הפרויקט", systemImage: "pencil")}
                    .disabled(model.busy)
            }
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
/// The GoPro ride computer over the edit preview, in step with playback:
/// a player item cannot draw the export's overlay, so the screen does.
private struct ReadoutOverlay: View {
    @ObservedObject var model: EditorModel
    let player: AVPlayer
    let active: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) {_ in
            if active, let readout = model.readout(at: player.currentTime().seconds) {ReadoutBadge(readout: readout)}
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(10)
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
    }
}
private struct ReadoutBadge: View {
    let readout: Telemetry.Readout
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(verbatim: "\(readout.speed)").font(RK.font(28, 700)).monospacedDigit()
                    .foregroundStyle(Color(red: 0.78, green: 0.96, blue: 0.26)).contentTransition(.numericText())
                Text(verbatim: Telemetry.unit).font(RK.font(11, 500)).foregroundStyle(.white.opacity(0.85))
            }
            Text(verbatim: Telemetry.detail(readout)).font(RK.font(10)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: readout)
    }
}

private struct ActionBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // Floats over the scrolling step on glass, so the work stays in view.
        VStack(spacing: 8) {content}
            .padding(10)
            .rkGlass(cornerRadius: 28)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
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
            Text(LocalizedStringKey(model.backgroundDescription)).font(RK.font(14)).foregroundStyle(RK.soft).multilineTextAlignment(.center)
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
    @State private var picked: [PhotosPickerItem] = []
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
                Text("בחרו סרטונים ותמונות").font(RK.font(22, 700, style: .title2)).foregroundStyle(RK.ink).rkRow(top: 4)
                Text("כמה סרטונים מתחברים לסרט אחד, לפי סדר הצילום. תמונות יקבלו תנועה משלהן.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).rkRow(top: 0)
                HStack(spacing: 10) {
                    PhotosPicker(selection: $picked, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .any(of: [.videos, .images]), preferredItemEncoding: .current) {SourceTile(title: "מהתמונות", symbol: "photo.on.rectangle")}
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
        .onChange(of: picked) {_, items in
            guard !items.isEmpty else {return}
            model.importPickedVideos(items); picked = []
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.movie, .image], allowsMultipleSelection: true) {result in
            switch result {
            case .success(let sources): Task {await model.importVideos(sources)}
            case .failure(let error): model.message = error.localizedDescription
            }
        }
    }
    private func details(_ project: LocalProject) -> String {
        var parts: [String] = []
        if project.joinsVideos {parts.append(String(format: NSLocalizedString("%@ סרטונים", comment: "How many videos a project joins"), "\(project.files.count)"))}
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
    @StateObject private var playback = PreviewPlayback()
    private var showingEdit: Bool {playback.showingEdit}
    @State private var trimming: TrimSelection?
    @State private var tuning = false
    @State private var styling = false
    @State private var fullScreen = false
    @State private var shuffled: [Clip]?
    private var upright: Bool {model.edit.settings["aspect"]?.string == "9:16"}
    var body: some View {
        List {
            VStack(spacing: 10) {
                VideoPlayer(player: playback.player) {ReadoutOverlay(model: model, player: playback.player, active: playback.showingEdit)}
                    .accessibilityIdentifier("edit.player")
                .frame(height: upright && showingEdit ? 300 : 210).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Button {fullScreen = true} label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(.black.opacity(0.45), in: Circle())
                    }.buttonStyle(.plain).padding(8).accessibilityLabel("מסך מלא")
                }
                HStack(spacing: 0) {
                    viewChoice("המקור", picked: !showingEdit) {showSource()}
                        .accessibilityIdentifier("edit.showSource")
                    viewChoice("העריכה", picked: showingEdit) {showEdit()}
                        .accessibilityIdentifier("edit.showEdit")
                        .disabled(model.busy || model.editValidationMessage != nil)
                }
                .padding(3).background(RK.card, in: Capsule())
            }.rkRow(top: 0)
            if model.work == .previewing {ProgressCard(model: model).rkRow()}
            if let reading = model.project?.reading {
                ReadingCard(reading: reading) {model.setKind($0)}.disabled(model.busy).rkRow()
            }
            if model.project?.scores.isEmpty == false {
                AskCard(model: model).disabled(model.busy).rkRow(top: 10)
                if !model.people.isEmpty {StarCard(model: model).disabled(model.busy).rkRow(top: 10)}
            }
            if let project = model.project, !project.scores.isEmpty {
                ActivityCard(project: project, clips: model.edit.clips, threshold: model.threshold, tune: {tuning = true}, seek: seek)
                    .disabled(model.busy).rkRow()
            }
            Button {styling = true} label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.system(size: 17, weight: .medium)).foregroundStyle(RK.accent)
                        .frame(width: 40, height: 40).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("סגנון").font(RK.font(15, 500)).foregroundStyle(RK.ink)
                        Text(verbatim: styleSummary).font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(RK.faint)
                }.padding(10).background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(model.busy).accessibilityIdentifier("edit.style").rkRow(top: 10)
            if model.edit.clips.count > 1, model.edit.settings["wholeVideo"]?.bool != true {
                ChoiceGroup(title: "אורך הסרט", options: [
                    (RK.seconds(30), "30"), (RK.seconds(45), "45"),
                    (NSLocalizedString("דקה", comment: "One minute movie length"), "60"),
                    (NSLocalizedString("הכל", comment: "Keep every suggested moment"), "all"),
                ], selection: Binding(get: {model.targetLength}, set: {model.pickLength($0)}))
                .disabled(model.busy).accessibilityIdentifier("edit.length").rkRow(top: 12)
            }
            if model.project?.scores.isEmpty == false, model.edit.settings["wholeVideo"]?.bool != true {
                ChoiceGroup(title: "אורך מקסימלי לקטע", options: [
                    (NSLocalizedString("ללא", comment: "No limit on clip length"), "off"),
                    (RK.seconds(3), "3"), (RK.seconds(5), "5"), (RK.seconds(8), "8"),
                ], selection: Binding(get: {model.edit.settings["maxClip"]?.string ?? "off"}, set: {model.setClipRule("maxClip", .text($0))}))
                .disabled(model.busy).accessibilityIdentifier("edit.maxClip").rkRow(top: 12)
                if model.project?.joinsVideos == true {
                    ToggleRow(title: "קטע מכל סרטון", detail: "גם סרטון בלי אקשן בולט יקבל לפחות קטע אחד",
                              isOn: Binding(get: {ClipRules.everyVideo(model.edit.settings)}, set: {model.setClipRule("everyVideo", .flag($0))}))
                        .rkCard().disabled(model.busy).accessibilityIdentifier("edit.everyVideo").rkRow(top: 12)
                }
            }
            clipsHeader.rkRow(top: 12)
            if model.edit.clips.count > 1 {clipTools.rkRow(top: 0, bottom: 4)}
            ForEach($model.edit.clips) {$clip in
                ClipRow(clip: $clip, canTrim: (model.project?.duration ?? 0) > 0.01, moment: moment(of: clip), video: videoTag(of: clip)) {trimming = TrimSelection(id: clip.id)}
                    .disabled(model.busy).rkRow(top: 4, bottom: 4)
            }
            .onMove {if !model.busy {model.edit.clips.move(fromOffsets: $0, toOffset: $1)}}
            .onDelete {if !model.busy {model.edit.clips.remove(atOffsets: $0)}}
            if model.edit.clips.isEmpty {
                Text("לא נמצאו רגעים בולטים. שנו רגישות או הוסיפו קטע ידני.").font(RK.font(14)).foregroundStyle(RK.soft).rkCard().rkRow()
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
                Button("המשך למוזיקה", action: next).buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
            }
        }
        .sheet(item: $trimming) {selection in
            if let index = model.edit.clips.firstIndex(where: {$0.id == selection.id}), let project = model.project, project.duration > 0.01 {
                // A clip is trimmed within its own video.
                let part = project.joinsVideos ? project.part(at: model.edit.clips[index].start) : ProjectPart(file: project.source, start: 0, duration: project.duration)
                ClipTrimView(clip: $model.edit.clips[index], source: LocalStore.file(part.file, project: project.id), offset: part.start, duration: part.duration)
            }
        }
        .sheet(isPresented: $tuning) {SensitivitySheet(model: model).presentationDetents([.height(320)])}
        .sheet(isPresented: $styling) {StyleSheet(model: model).presentationDetents([.medium, .large])}
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: playback.player) {ReadoutOverlay(model: model, player: playback.player, active: playback.showingEdit)}.ignoresSafeArea()
                Button {fullScreen = false} label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle())
                }.buttonStyle(.plain).padding(16).accessibilityLabel("סגירת המסך המלא")
            }
        }
        .onAppear {
            if let preview = model.previewEdit {playback.showEdit(preview)}
            else if !showingEdit {showSource()}
        }
        .onChange(of: model.joinedSource) {_, _ in if !showingEdit {showSource()}}
        .onChange(of: model.previewEdit) {_, preview in
            if let preview {playback.showEdit(preview, play: true)}
            else if showingEdit {showSource()}
        }
        .onDisappear {playback.pause()}
    }
    private func viewChoice(_ title: LocalizedStringKey, picked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(RK.font(14, picked ? 500 : 400)).foregroundStyle(picked ? RK.accentInk : RK.soft)
                .frame(maxWidth: .infinity, minHeight: 36).background(picked ? RK.accent : Color.clear, in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(picked ? .isSelected : [])
    }
    /// Where the activity graph was tapped, shown in the source.
    private func seek(_ time: Double) {
        if showingEdit {showSource()}
        playback.player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    /// The video file and the second in it that a clip's picture comes from.
    private func moment(of clip: Clip) -> (URL, Double)? {
        guard let project = model.project, clip.duration.isFinite, clip.duration > 0 else {return nil}
        let middle = (clip.start + clip.end) / 2
        let part = project.part(at: middle)
        return (LocalStore.file(part.file, project: project.id), middle - part.start)
    }
    /// "Video 2" on a clip, in a project made of several videos.
    private func videoTag(of clip: Clip) -> String? {
        guard let project = model.project, project.joinsVideos, let index = project.pieces.firstIndex(of: project.part(at: clip.start)) else {return nil}
        return String(format: NSLocalizedString("סרטון %@", comment: "Which of a project's videos a clip comes from"), "\(index + 1)")
    }
    private var styleSummary: String {
        let settings = model.edit.settings
        let transition = settings["transition"]?.string ?? "cut"
        var parts = [String(format: NSLocalizedString("מעברים: %@", comment: "Style summary: the transitions"), StyleSheet.transitionName(transition))]
        if let speed = settings["speed"]?.string, speed != "1" {parts.append(speed + "×")}
        let slow = SlowMotion.mode(settings)
        if slow == "peak", model.project?.scores.isEmpty == false {parts.append(NSLocalizedString("האטה בשיא", comment: "Style summary: slow motion on the peak"))}
        else if slow == "each", model.project?.scores.isEmpty == false {parts.append(NSLocalizedString("האטה בכל קטע", comment: "Style summary: slow motion on every clip"))}
        let marked = model.edit.clips.filter {$0.selected != false && $0.slowAt != nil}.count
        if marked > 0 {parts.append(String(format: NSLocalizedString("%@ קטעים מסומנים להאטה", comment: "Style summary: clips the rider marked for slow motion"), "\(marked)"))}
        return parts.joined(separator: " · ")
    }
    private func showSource() {
        if let joined = model.joinedSource {playback.showSource(joined)} else {playback.showSource(model.sourceURL)}
    }
    private func showEdit() {
        if let preview = model.previewEdit {playback.showEdit(preview)}
        else {model.preview()}
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
    /// Shuffle and automatic choice, as beside the web app's clip list.
    private var clipTools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tool("ערבוב סדר", symbol: "shuffle") {model.shuffleClips(); shuffled = model.edit.clips}
                if let shuffled, shuffled == model.edit.clips, model.undoAvailable {
                    tool("ביטול ערבוב", symbol: "arrow.uturn.backward") {model.undo(); self.shuffled = nil}
                }
            }
        }.disabled(model.busy)
    }
    private func tool(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {toolLabel(title, symbol: symbol)}.buttonStyle(.plain)
    }
    private func toolLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.ink)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(RK.card, in: Capsule()).overlay(Capsule().stroke(RK.line))
    }
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.edit.settings[key] = .text($0)})
    }
    private func addClip() {
        // Edited-preview time is not a timestamp in the original.
        let playhead = showingEdit ? 0 : playback.player.currentTime().seconds
        guard let project = model.project else {return}
        // The joined source plays the project's own timeline; a clip stays inside one video.
        let at = playhead.isFinite ? max(0, playhead) : 0
        let part = project.joinsVideos ? project.part(at: at) : ProjectPart(file: project.source, start: 0, duration: project.duration)
        let start = min(max(part.start, at), max(part.start, part.end - 1))
        var clip = Clip(start: start, end: min(part.end, start + 5)); clip.manual = true
        model.edit.clips.append(clip)
    }
}

/// What the scan found the video to be and how it will be edited, with a
/// way to pick another kind when it read the video wrong.
private struct ReadingCard: View {
    let reading: ContentReading
    let pick: (ContentKind) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: reading.kind.symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(RK.accent)
                    .frame(width: 44, height: 44)
                    .background(RK.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    (reading.kind == reading.detected ? Text("זיהיתי") : Text("נערך לפי הבחירה שלך"))
                        .font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                    Text(verbatim: reading.kind.title).font(RK.font(17, 600, style: .headline)).foregroundStyle(RK.ink)
                }
                Spacer()
                Menu {
                    ForEach(ContentKind.allCases) {kind in
                        Button {pick(kind)} label: {Label(kind.title, systemImage: kind.symbol)}
                    }
                } label: {
                    Text("שינוי").font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.ink)
                        .padding(.horizontal, 12).frame(minHeight: 32).overlay(Capsule().stroke(RK.line))
                }
                .accessibilityLabel("שינוי סוג התוכן")
                .accessibilityIdentifier("reading.change")
            }
            if !reading.facts.isEmpty {
                Text(verbatim: reading.facts.joined(separator: " · "))
                    .font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: reading.kind.plan).font(RK.font(14)).foregroundStyle(RK.ink).fixedSize(horizontal: false, vertical: true)
            if let other = reading.runnerUp, other != reading.kind {
                Button {pick(other)} label: {
                    Label(String(format: NSLocalizedString("אולי זה %@?", comment: "One-tap switch to the second most likely content kind"), other.title), systemImage: other.symbol)
                        .font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.accentSoftInk)
                        .padding(.horizontal, 12).frame(minHeight: 34).background(RK.accentSoft, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("reading.runnerUp")
            }
        }
        .rkCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reading.card")
    }
}

/// The video's standout moments over time, on a strip of its own frames,
/// with the chosen ones lit up and a line where one video meets the next.
/// A tap shows that moment in the source.
private struct ActivityCard: View {
    let project: LocalProject
    let clips: [Clip]
    let threshold: Double
    let tune: () -> Void
    let seek: (Double) -> Void
    private static let frames = 8
    @State private var strip: [UIImage?] = Array(repeating: nil, count: ActivityCard.frames)
    private var scores: [Double] {project.scores}
    private var duration: Double {project.duration}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("רגעים בולטים לאורך הסרטון").font(RK.font(14, 500)).foregroundStyle(RK.ink)
                Spacer()
                Button(action: tune) {
                    Text(verbatim: String(format: NSLocalizedString("רגישות · %@", comment: "Detection sensitivity chip"), level))
                        .font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                        .padding(.horizontal, 10).frame(minHeight: 32).overlay(Capsule().stroke(RK.line))
                }.buttonStyle(.plain)
            }
            GeometryReader {geometry in
                let width = max(1, geometry.size.width)
                ZStack(alignment: .bottomLeading) {
                    HStack(spacing: 1) {
                        ForEach(0..<Self.frames, id: \.self) {index in
                            Group {
                                if let image = strip[index] {Image(uiImage: image).resizable().scaledToFill()} else {RK.raised}
                            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        }
                    }
                    .opacity(0.45)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(Array(bars.enumerated()), id: \.offset) {_, bar in
                            RoundedRectangle(cornerRadius: 2).fill(bar.color).frame(maxWidth: .infinity).frame(height: 6 + bar.value * 46)
                        }
                    }.padding(.horizontal, 2)
                    ForEach(seams, id: \.self) {seam in
                        Rectangle().fill(RK.ink.opacity(0.7)).frame(width: 2).offset(x: CGFloat(seam / max(duration, 0.01)) * width - 1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {location in seek(Double(location.x / width) * duration)}
            }
            .frame(height: 60)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement().accessibilityLabel("גרף הרגעים הבולטים לאורך הסרטון")
            .accessibilityValue(summary)
            HStack {
                ForEach(0..<4) {i in
                    Text(verbatim: RK.clock(duration * Double(i) / 3))
                    if i < 3 {Spacer()}
                }
            }.font(RK.font(11, 400, style: .caption2)).monospacedDigit().foregroundStyle(RK.faint)
            .environment(\.layoutDirection, .leftToRight)
        }
        .rkCard()
        .task(id: project.id + "\(duration)") {
            for index in 0..<Self.frames {
                let time = (Double(index) + 0.5) / Double(Self.frames) * duration
                let part = project.part(at: time)
                let image = await Thumbnails.shared.frame(LocalStore.file(part.file, project: project.id), at: time - part.start)
                if Task.isCancelled {return}
                strip[index] = image
            }
        }
    }
    private var seams: [Double] {project.joinsVideos ? project.pieces.dropFirst().map(\.start) : []}
    /// "3 moments chosen, the strongest at 1:42", for VoiceOver.
    private var summary: String {
        let chosen = clips.filter {$0.selected != false}.count
        guard let peak = scores.indices.max(by: {scores[$0] < scores[$1]}), !scores.isEmpty else {return clipCount(chosen)}
        let time = (Double(peak) + 0.5) / Double(scores.count) * duration
        return String(format: NSLocalizedString("%1$@ נבחרו, הרגע החזק ביותר ב־%2$@", comment: "Activity graph summary for VoiceOver"), clipCount(chosen), RK.clock(time))
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
    /// The video file and second the row's picture comes from.
    let moment: (URL, Double)?
    /// Which video the clip comes from, in a project of several.
    let video: String?
    let trim: () -> Void
    @State private var image: UIImage?
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
            Group {
                if let image {Image(uiImage: image).resizable().scaledToFill()} else {RK.raised}
            }
            .frame(width: 56, height: 42).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).accessibilityHidden(true)
            .task(id: moment.map {$0.0.lastPathComponent + "\($0.1)"}) {
                guard let moment else {image = nil; return}
                image = await Thumbnails.shared.frame(moment.0, at: moment.1)
            }
            VStack(alignment: .leading, spacing: 2) {
                // Isolated, so "0:36–1:12" keeps its order inside Hebrew text.
                Text(verbatim: "\u{2066}\(RK.clock(clip.start))–\(RK.clock(clip.end))\u{2069}").font(RK.font(15, 500)).monospacedDigit().foregroundStyle(RK.ink)
                Text(verbatim: [RK.seconds(clip.duration), video].compactMap {$0}.joined(separator: " · ")).font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            }
            Spacer(minLength: 0)
            if clip.slowAt != nil {
                Image(systemName: "tortoise.fill").font(.system(size: 13)).foregroundStyle(RK.accent)
                    .accessibilityLabel("הילוך איטי בקטע")
            }
            if let score = clip.score, score >= 0.8 {Pill(text: NSLocalizedString("רגע שיא", comment: "A clip among the video's strongest moments"))}
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
            Text("רגישות זיהוי הרגעים").font(RK.font(19, 700, style: .title3)).foregroundStyle(RK.ink)
            // Higher sensitivity is a lower activity threshold, so more clips.
            Slider(value: Binding(get: {1.15 - model.threshold}, set: {model.threshold = 1.15 - $0}), in: 0.25...0.9, step: 0.05) {
                Text("רגישות זיהוי הרגעים")
            } minimumValueLabel: {
                Text("פחות קטעים").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            } maximumValueLabel: {
                Text("יותר קטעים").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            }.tint(RK.accent)
            Text("הרגעים המוצעים יוחלפו; ניתן לבטל את השינוי.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            Spacer(minLength: 0)
            Button("הפקת הצעות מחדש") {model.retune(); dismiss()}.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
        }
        .padding(20)
        .presentationBackground(RK.bg)
        .environment(\.layoutDirection, AppLanguage.direction)
    }
}

/// The moment the scan finishes: what it found, what it made of it, and
/// two ways on, to the finished movie or into the edit.
private struct RevealSheet: View {
    @ObservedObject var model: EditorModel
    let quick: () -> Void
    let control: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reading = model.project?.reading {
                Spacer(minLength: 12)
                Image(systemName: reading.kind.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(RK.accent)
                    .frame(width: 72, height: 72)
                    .background(RK.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                (reading.kind == reading.detected ? Text("זיהיתי") : Text("נערך לפי הבחירה שלך"))
                    .font(RK.font(15)).foregroundStyle(RK.soft)
                Text(verbatim: reading.kind.title).font(RK.font(28, 700, style: .title1)).foregroundStyle(RK.ink)
                    .accessibilityIdentifier("reveal.kind")
                if !reading.facts.isEmpty {
                    Text(verbatim: reading.facts.joined(separator: " · ")).font(RK.font(14)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: reading.kind.plan).font(RK.font(16)).foregroundStyle(RK.ink).fixedSize(horizontal: false, vertical: true)
                Menu {
                    ForEach(ContentKind.allCases) {kind in
                        Button {model.setKind(kind)} label: {Label(kind.title, systemImage: kind.symbol)}
                    }
                } label: {
                    Text("לא זה? בחירת סוג אחר").font(RK.font(14, 500)).foregroundStyle(RK.accent)
                }.disabled(model.busy)
                VStack(alignment: .leading, spacing: 6) {
                    Text("מה הכנתי").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                    Text(verbatim: prepared).font(RK.font(15, 500)).foregroundStyle(RK.ink).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).rkCard()
            }
            Spacer()
            Button("קדימה, לסרט", action: quick).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("reveal.quick")
            Button("עריכה ידנית", action: control).buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("reveal.control")
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RK.bg.ignoresSafeArea())
        .environment(\.layoutDirection, AppLanguage.direction)
    }
    /// "0:45 · 6 clips · smart transitions · 9:16".
    private var prepared: String {
        let chosen = model.selectedClips
        let length = model.movieDuration ?? chosen.reduce(0) {$0 + $1.duration}
        var parts = [RK.clock(length), clipCount(chosen.count)]
        parts.append(String(format: NSLocalizedString("מעברים: %@", comment: "Style summary: the transitions"), StyleSheet.transitionName(model.edit.settings["transition"]?.string ?? "cut")))
        if model.edit.settings["aspect"]?.string == "9:16" {parts.append(NSLocalizedString("סטורי 9:16", comment: "Story framing"))}
        return parts.joined(separator: " · ")
    }
}

/// How the movie moves: transitions, speed and slow motion, behind one row
/// of the edit step so the clips stay in view.
private struct StyleSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: String?
    /// Two frames of the movie for the transition previews.
    @State private var shots: [UIImage?] = [nil, nil]
    static let transitions = [SmartTransitions.name, "cut", "dissolve", "fade", "flash", "slide", "zoom"]
    static func transitionName(_ value: String) -> String {StyleSheetNames.transition(value)}
    static func slowModeName(_ value: String) -> String {
        switch value {
        case "peak": return NSLocalizedString("ברגע השיא", comment: "Slow motion on the movie's strongest moment")
        case "each": return NSLocalizedString("בכל קטע", comment: "Slow motion on every clip's strongest moment")
        default: return NSLocalizedString("רק בקטעים שסימנתי", comment: "Slow motion only where the rider marked it")
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TransitionPicker(options: Self.transitions, selection: setting("transition", fallback: "cut"), first: shots[0], second: shots[1])
                    if transition == SmartTransitions.name {
                        Text("לכל חיבור אבחר מעבר לפי מה שקורה בו.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                            .accessibilityIdentifier("edit.smartNote")
                        if let plan {Text(verbatim: plan).font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.ink).fixedSize(horizontal: false, vertical: true)}
                    }
                    if transition != "cut" {
                        ChoiceGroup(title: "משך המעבר", options: ["0.3", "0.5", "1"].map {(String(format: NSLocalizedString("%@ שניות", comment: "Seconds value"), $0), $0)}, selection: setting("transitionDuration", fallback: "0.5"))
                    }
                    ChoiceGroup(title: "מהירות", options: ["1", "1.25", "1.5", "2"].map {($0 + "×", $0)}, selection: setting("speed", fallback: "1"))
                    VStack(alignment: .leading, spacing: 10) {
                        Label("הילוך איטי", systemImage: "tortoise").font(RK.font(15, 600)).foregroundStyle(RK.ink)
                        if model.project?.scores.isEmpty == false {
                            ChoiceGroup(title: "איפה", options: SlowMotion.modes.map {(Self.slowModeName($0), $0)},
                                        selection: Binding(get: {SlowMotion.mode(model.edit.settings)}, set: {model.setTiming("slowMode", $0)}))
                                .accessibilityIdentifier("edit.slowMode")
                        }
                        ChoiceGroup(title: "כמה לאט", options: SlowMotion.rates.map {(String(format: NSLocalizedString("פי %@", comment: "Slow motion factor"), $0), $0)},
                                    selection: setting("slowRate", fallback: "2"))
                        ChoiceGroup(title: "משך ההאטה", options: SlowMotion.lengths.map {(String(format: NSLocalizedString("%@ שניות", comment: "Seconds value"), $0), $0)},
                                    selection: setting("slowLength", fallback: "1.5"))
                        ToggleRow(title: "האצה לפני ואחרי ההאטה", detail: "speed ramp: הסרט רץ מהר אל הרגע ומאט בו", isOn: timingFlag("speedRamp"))
                            .accessibilityIdentifier("edit.speedRamp")
                        Text("אפשר לסמן הילוך איטי גם בקטע מסוים: פתחו אותו בכפתור המספריים.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                    }.rkCard()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("אפקטים", systemImage: "sparkles").font(RK.font(15, 600)).foregroundStyle(RK.ink)
                        if model.project?.scores.isEmpty == false {
                            ToggleRow(title: "פתיח הוק", detail: "שתי שניות מרגע השיא בפתיחה, לפני שהסרט מתחיל", isOn: timingFlag("hook"))
                                .accessibilityIdentifier("edit.hook")
                        }
                        ToggleRow(title: "זום על הביט", detail: "דחיפה קטנה פנימה על כל ביט שני של השיר", isOn: flag("beatZoom"))
                            .accessibilityIdentifier("edit.beatZoom")
                        ToggleRow(title: "סאונד ווש במעברים", detail: "משב קל מתחת לכל מעבר שאינו חיתוך", isOn: flag("whoosh"))
                            .accessibilityIdentifier("edit.whoosh")
                    }.rkCard()
                }.padding(20).disabled(model.busy)
            }
            .background(RK.bg.ignoresSafeArea())
            .navigationTitle("סגנון").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement: .confirmationAction) {Button("בוצע") {dismiss()}}}
        }
        .tint(RK.accent)
        .environment(\.layoutDirection, AppLanguage.direction)
        .task(id: model.edit.clips) {plan = smartPlan()}
        .task(id: model.project?.id) {
            guard let p = model.project else {return}
            let chosen = model.edit.clips.filter {$0.selected != false}.prefix(2)
            for (index, clip) in chosen.enumerated() {
                let middle = (clip.start + clip.end) / 2, part = p.part(at: middle)
                shots[index] = await Thumbnails.shared.frame(LocalStore.file(part.file, project: p.id), at: middle - part.start)
            }
        }
    }
    private var transition: String {model.edit.settings["transition"]?.string ?? "cut"}
    /// "In this movie: 3 zoom, 2 dissolve", from the same choice the export makes.
    private func smartPlan() -> String? {
        guard let p = model.project else {return nil}
        let clips = model.edit.clips.filter {$0.selected != false}
        guard clips.count > 1 else {return nil}
        let styles = SmartTransitions.styles(for: clips, signals: LocalStore.readSignals(project: p.id), kind: p.reading?.kind, pieces: p.pieces)
        let counts = Dictionary(grouping: styles, by: {$0}).map {($0.key, $0.value.count)}.sorted {($0.1, $1.0) > ($1.1, $0.0)}
        let list = counts.map {"\($0.1) " + Self.transitionName($0.0)}.joined(separator: ", ")
        return String(format: NSLocalizedString("בסרט הזה: %@", comment: "Which smart transitions this movie gets"), list)
    }
    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: {model.edit.settings[key]?.bool ?? false}, set: {model.edit.settings[key] = .flag($0)})
    }
    /// A switch that changes the movie's length, so the clips are chosen again for it.
    private func timingFlag(_ key: String) -> Binding<Bool> {
        Binding(get: {model.edit.settings[key]?.bool ?? false}, set: {model.setTiming(key, $0 ? "true" : "false")})
    }
    /// Each of these changes the movie's length, so the clips are chosen again for it.
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.setTiming(key, $0)})
    }
}

/// The movie as it will come out, with its music, framing and colour, on
/// the steps after the edit. Any change clears it until it is built again.
private struct EditPreviewCard: View {
    @ObservedObject var model: EditorModel
    /// Builds the preview as soon as the card shows, as on the export step.
    var automatic = false
    @StateObject private var playback = PreviewPlayback()
    @State private var built = false
    var body: some View {
        VStack(spacing: 8) {
            if model.previewEdit != nil {
                VideoPlayer(player: playback.player) {ReadoutOverlay(model: model, player: playback.player, active: true)}
                    .frame(height: upright ? 320 : 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("preview.player")
            } else {
                Button {built = true; model.preview()} label: {
                    if model.work == .previewing {ProgressView().tint(RK.accent)}
                    else {Label(built ? LocalizedStringKey("עדכון התצוגה המקדימה") : LocalizedStringKey("צפייה בסרט לפני הייצוא"), systemImage: "play.rectangle")}
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.busy || model.editValidationMessage != nil)
                .accessibilityIdentifier("preview.build")
                if built {
                    Text("הוחל שינוי מאז התצוגה האחרונה.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                }
            }
        }
        .onAppear {
            if let preview = model.previewEdit {built = true; playback.showEdit(preview)}
            else if automatic, !model.busy, model.editValidationMessage == nil {built = true; model.preview()}
        }
        .onChange(of: model.previewEdit) {_, preview in
            if let preview {playback.showEdit(preview, play: true)} else {playback.showSource(Optional<URL>.none)}
        }
        .onDisappear {playback.pause()}
    }
    private var upright: Bool {model.edit.settings["aspect"]?.string == "9:16"}
}

// MARK: - Music

/// Songs to search for, chosen from what the scan found the video to be.
private struct SongIdeasCard: View {
    let reading: ContentReading
    let named: [SongIdeas.Idea]
    let thinking: Bool
    /// The idea whose top search result is being added, if any.
    let adding: String?
    let search: (SongIdeas.Idea) -> Void
    let add: (SongIdeas.Idea) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(RK.accent).accessibilityHidden(true)
                Text("שירים שמתאימים לסרטון").font(RK.font(16, 600, style: .headline)).foregroundStyle(RK.ink)
                Spacer()
                if thinking {ProgressView().tint(RK.accent)}
            }
            let tempo = SongIdeas.tempo(for: reading)
            Text(verbatim: String(format: NSLocalizedString("לפי מה שזיהיתי: %@, בקצב של %ld–%ld פעימות לדקה", comment: "Why these songs are suggested"),
                                  reading.kind.title, tempo.lowerBound, tempo.upperBound))
                .font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true)
            if !named.isEmpty {
                ForEach(named) {idea in
                    HStack(spacing: 8) {
                        Button {search(idea)} label: {
                            HStack(spacing: 10) {
                                Image(systemName: "music.note").foregroundStyle(RK.accent).accessibilityHidden(true)
                                Text(verbatim: idea.title).font(RK.font(14, 500)).foregroundStyle(RK.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(RK.faint)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }.buttonStyle(.plain)
                        .accessibilityLabel(String(format: NSLocalizedString("חיפוש %@ ב־YouTube", comment: "Search a suggested song"), idea.title))
                        Button {add(idea)} label: {
                            Group {
                                if adding == idea.id {ProgressView().tint(RK.accentSoftInk)}
                                else {Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(RK.accentSoftInk)}
                            }
                            .frame(width: 44, height: 44).background(RK.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain).disabled(adding != nil)
                        .accessibilityLabel(String(format: NSLocalizedString("הוספת %@ לפרויקט", comment: "Add a found song"), idea.title))
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SongIdeas.ideas(for: reading)) {idea in
                        Button {search(idea)} label: {
                            Text(verbatim: idea.title).font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.accentSoftInk)
                                .padding(.horizontal, 12).frame(minHeight: 34)
                                .background(RK.accentSoft, in: Capsule())
                        }.buttonStyle(.plain)
                        .accessibilityLabel(String(format: NSLocalizedString("חיפוש %@ ב־YouTube", comment: "Search a suggested song"), idea.title))
                    }
                }
            }
            .accessibilityIdentifier("music.ideas")
        }
        .rkCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music.ideasCard")
    }
}

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
    @StateObject private var listening = SongPreview()
    @State private var fetching: String?
    @State private var added: Set<String> = []
    @State private var choosing: LocalMusic?
    @State private var named: [SongIdeas.Idea] = []
    @State private var thinking = false
    @State private var adding: String?
    var body: some View {
        List {
            if !songs.isEmpty {EditPreviewCard(model: model).rkRow(top: 0)}
            if let reading = model.project?.reading {
                SongIdeasCard(reading: reading, named: named, thinking: thinking, adding: adding, search: {idea in
                    showYouTube = true; query = idea.query; go()
                }, add: addIdea).disabled(model.busy || searching).rkRow()
                Text("שיר אחר").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).rkRow(top: 10, bottom: 0)
            }
            HStack(spacing: 10) {
                Button {showImporter = true} label: {SourceTile(title: "מהקבצים", symbol: "folder")}
                Button {showYouTube.toggle()} label: {SourceTile(title: "מ־YouTube", symbol: "play.rectangle.fill", picked: showYouTube)}
                    .accessibilityIdentifier("music.youtube")
            }.buttonStyle(.plain).disabled(model.busy).rkRow()
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
                    ToggleRow(title: "חיתוך לפי קצב השיר", detail: "כל מעבר בין קטעים נופל על הביט של השיר הראשון", isOn: flag("beatSync", fallback: true))
                }
                ToggleRow(title: "השתקת קול המקור", detail: "קולות, מוזיקה ורעשים מהצילום עצמו", isOn: flag("muteOriginal", fallback: false))
                if !songs.isEmpty, model.edit.settings["muteOriginal"]?.bool != true {
                    ToggleRow(title: "הנמכת המוזיקה כשמדברים או צוחקים", detail: "המוזיקה יורדת לבד ברגעים שבהם שומעים את האנשים בסרטון", isOn: flag("duckMusic", fallback: true))
                }
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
        // The on-device model names songs for what the scan found, once per kind.
        .task(id: model.project?.reading?.kind) {
            guard let reading = model.project?.reading else {named = []; return}
            thinking = true
            let found = await SongIdeas.named(for: reading, seconds: model.movieDuration)
            if !Task.isCancelled {named = found; thinking = false}
        }
        .onDisappear {searchTask?.cancel(); listening.stop()}
        // A song whose row goes away stops with it.
        .onChange(of: results) {listening.stop()}
        .onChange(of: showYouTube) {listening.stop()}
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
                        .accessibilityLabel("חיפוש שיר ב־YouTube").accessibilityIdentifier("music.query")
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
                if let failure = listening.failure {Text(verbatim: failure).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)}
                else {Text("השמע יורד ישירות לאייפון.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint)}
            }
        }.rkCard()
    }
    /// One tap from a suggestion to the song in the project: its top search result is added.
    private func addIdea(_ idea: SongIdeas.Idea) {
        guard !model.busy, adding == nil else {return}
        adding = idea.id; searchNote = nil
        Task {
            defer {adding = nil}
            do {
                guard let top = try await YouTubeSearch.search(idea.query).first else {
                    searchNote = NSLocalizedString("לא נמצאו תוצאות. נסו שם אחר.", comment: "YouTube search found nothing"); showYouTube = true; return
                }
                listening.stop(); fetching = top.id; model.importYouTube(link: top.link)
            } catch {searchNote = error.localizedDescription; showYouTube = true}
        }
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
            Button {listening.toggle(result.id, link: result.link)} label: {
                Group {
                    if listening.loading == result.id {ProgressView().tint(RK.accent)}
                    else {Image(systemName: listening.playing == result.id ? "stop.fill" : "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(RK.ink)}
                }
                .frame(width: 40, height: 40).background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("music.listen")
            .accessibilityLabel(listening.playing == result.id
                ? String(format: NSLocalizedString("עצירת %@", comment: "Stop a found song"), result.title)
                : String(format: NSLocalizedString("האזנה ל־%@", comment: "Listen to a found song"), result.title))
            if fetching == result.id {
                ProgressView().tint(RK.accent).frame(width: 40, height: 40)
            } else if added.contains(result.id) {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(RK.accent).frame(width: 40, height: 40)
                    .accessibilityLabel("השיר נוסף לפרויקט")
            } else {
                Button {listening.stop(); fetching = result.id; model.importYouTube(link: result.link)} label: {
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
    @State private var naming = false
    @State private var advanced = false
    @State private var suggestion: MovieWords.Words?
    var body: some View {
        List {
            EditPreviewCard(model: model, automatic: true).rkRow(top: 0)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.movieDuration.map(RK.clock) ?? "–").font(RK.font(34, 700, style: .largeTitle)).monospacedDigit().foregroundStyle(RK.ink)
                        .accessibilityIdentifier("export.length")
                    Text(model.beatChangesLength ? LocalizedStringKey("אורך הסרט, עם החיתוכים על הקצב") : LocalizedStringKey("אורך הסרט")).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                }
                Rectangle().fill(RK.line).frame(width: 1, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: contents).font(RK.font(14, 500)).foregroundStyle(RK.ink).lineLimit(2)
                    Text(verbatim: model.expectedFormat).font(RK.font(12, 400, style: .caption1)).monospacedDigit().foregroundStyle(RK.soft)
                }
                Spacer(minLength: 0)
            }.rkCard(padding: 16).rkRow()
            Group {
                ChoiceGroup(title: "יעד", options: [("Instagram", "instagram"), ("WhatsApp", "whatsapp"), (NSLocalizedString("מקורי", comment: "Keep the source's frame and resolution"), "original")],
                            selection: Binding(get: {destination}, set: setDestination))
                    .accessibilityIdentifier("export.destination")
                DisclosureGroup(isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        ChoiceGroup(title: "מסגרת", options: [(NSLocalizedString("מקור", comment: "Source framing"), "source"), (NSLocalizedString("סטורי 9:16", comment: "Story framing"), "9:16")], selection: setting("aspect", fallback: "source"))
                        ChoiceGroup(title: "איכות", options: [("1080p", "1080"), ("720p", "720"), (NSLocalizedString("רזולוציית מקור", comment: "Original resolution"), "original"), ("WhatsApp", "whatsapp")], selection: setting("quality", fallback: "1080"))
                    }.padding(.top, 10)
                } label: {
                    Text("מסגרת ואיכות").font(RK.font(14, 500)).foregroundStyle(RK.ink)
                }.tint(RK.soft)
                if model.edit.settings["aspect"]?.string == "9:16", model.project?.reading != nil {
                    ToggleRow(title: "מסגור חכם לפי האנשים", detail: "החיתוך האנכי עוקב אחרי האנשים בכל קטע במקום להישאר במרכז", isOn: flag("smartFrame", fallback: true))
                }
                ToggleRow(title: "מסך סיום עם הלוגו", detail: "בסוף הסרט התמונה עוברת למסך שבו הלוגו של RK Motion מופיע באנימציה", isOn: flag("outro", fallback: true))
                if model.hasTelemetry {
                    ToggleRow(title: "נתוני הרכיבה על הסרט", detail: "מהירות, גובה ומרחק מה־GPS של ה־GoPro", isOn: flag("telemetry", fallback: true))
                }
                if model.project?.reading != nil {
                    ChoiceGroup(title: "צבע", options: [(NSLocalizedString("לפי האווירה ✨", comment: "Colour grade chosen for the content kind"), "auto"), (NSLocalizedString("מקורי", comment: "No colour grade"), "none")], selection: setting("look", fallback: "auto"))
                }
            }.disabled(model.busy).rkRow()
            VStack(alignment: .leading, spacing: 10) {
                Text("כותרת פתיחה").font(RK.font(15, 500)).foregroundStyle(RK.ink)
                titleField("שם האירוע, המקום או האנשים", key: "titleText")
                titleField("מקום ותאריך", key: "subtitleText")
                Text("מופיעה בשניות הראשונות של הסרט. השאירו ריק לסרט בלי כותרת.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint)
                if let suggestion, (model.edit.settings["titleText"]?.string ?? "").isEmpty {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("הצעה").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                            Text(verbatim: [suggestion.title, suggestion.subtitle].filter {!$0.isEmpty}.joined(separator: " · ")).font(RK.font(14, 500)).foregroundStyle(RK.ink).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button("שימוש") {use(suggestion)}.font(RK.font(14, 500)).foregroundStyle(RK.accent).buttonStyle(.plain)
                            .accessibilityIdentifier("export.useSuggestion")
                    }
                    .padding(12).background(RK.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                Button(action: suggestWords) {
                    if naming {ProgressView().tint(RK.accent)}
                    else {Label("הצעה לכותרת ולכיתוב ✨", systemImage: "sparkles")}
                }
                .buttonStyle(SecondaryButtonStyle()).disabled(naming)
                .accessibilityIdentifier("export.suggestWords")
                if let caption = model.edit.settings["caption"]?.string, !caption.isEmpty {CaptionRow(caption: caption)}
            }.rkCard(padding: 16).disabled(model.busy).rkRow(top: 10)
            if model.movieURL != nil {
                Button(action: showMovie) {Label("לסרט האחרון שנוצר", systemImage: "play.rectangle")}
                    .buttonStyle(SecondaryButtonStyle()).disabled(model.busy).rkRow()
            }
            if model.busy {ProgressCard(model: model).rkRow()}
            MessageCard(model: model).rkRow()
        }
        .rkScreen()
        .task(id: model.project?.id) {await model.checkTelemetry()}
        .task(id: model.project?.id) {await prepareSuggestion()}
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                if let problem = model.editValidationMessage {
                    Text(LocalizedStringKey(problem)).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.danger).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {model.exportMovie()} label: {Label("ייצוא הסרט", systemImage: "film.stack")}
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy || model.selectedClips.isEmpty || model.editValidationMessage != nil)
                if model.edit.settings["wholeVideo"]?.bool != true, model.edit.clips.count > 1 {
                    Button {model.exportVersions()} label: {Label("3 גרסאות: סטורי 15, ריל 30, וואטסאפ 60", systemImage: "square.stack.3d.up")}
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.busy || model.selectedClips.isEmpty || model.editValidationMessage != nil)
                        .accessibilityIdentifier("export.versions")
                }
            }
        }
    }
    /// The one choice most movies need: where it is going.
    private var destination: String {
        let aspect = model.edit.settings["aspect"]?.string ?? "source", quality = model.edit.settings["quality"]?.string ?? "1080"
        if quality == "whatsapp" && aspect == "9:16" {return "whatsapp"}
        if quality == "1080" && aspect == "9:16" {return "instagram"}
        if quality == "original" && aspect != "9:16" {return "original"}
        return ""
    }
    private func setDestination(_ value: String) {
        var settings = model.edit.settings
        switch value {
        case "instagram": settings["aspect"] = .text("9:16"); settings["quality"] = .text("1080")
        case "whatsapp": settings["aspect"] = .text("9:16"); settings["quality"] = .text("whatsapp")
        default: settings["aspect"] = .text("source"); settings["quality"] = .text("original")
        }
        model.edit.settings = settings
    }
    private func use(_ words: MovieWords.Words) {
        var settings = model.edit.settings
        settings["titleText"] = .text(String(words.title.prefix(Edit.titleLimit)))
        settings["subtitleText"] = .text(String(words.subtitle.prefix(Edit.titleLimit)))
        settings["caption"] = .text(words.caption)
        model.edit.settings = settings
    }
    private var contents: String {
        let clips = clipCount(model.selectedClips.count)
        let songs = model.project?.music ?? []
        guard model.edit.settings["useMusic"]?.bool != false, let first = songs.first else {return clips + " · " + NSLocalizedString("ללא מוזיקה", comment: "No music in the movie")}
        return clips + " · " + (songs.count == 1 ? first.name : String(format: NSLocalizedString("%@ שירים", comment: "Song count"), "\(songs.count)"))
    }
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.edit.settings[key] = .text($0)})
    }
    private func flag(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(get: {model.edit.settings[key]?.bool ?? fallback}, set: {model.edit.settings[key] = .flag($0)})
    }
    /// A title waits beside an empty field, from what the scan found, for one tap to use.
    private func prepareSuggestion() async {
        guard suggestion == nil, let project = model.project, let reading = project.reading,
              (model.edit.settings["titleText"]?.string ?? "").isEmpty else {return}
        suggestion = await MovieWords.suggest(for: reading, date: project.created, language: Bundle.main.preferredLocalizations.first)
    }
    /// Fills the opening title and a post caption from what the scan found.
    private func suggestWords() {
        guard let project = model.project, !naming else {return}
        naming = true
        Task {
            let words: MovieWords.Words
            if let reading = project.reading {
                words = await MovieWords.suggest(for: reading, date: project.created, language: Bundle.main.preferredLocalizations.first)
            } else {
                words = MovieWords.fallback(for: .general, date: project.created)
            }
            model.edit.settings["titleText"] = .text(words.title)
            model.edit.settings["subtitleText"] = .text(words.subtitle)
            model.edit.settings["caption"] = .text(words.caption)
            naming = false
        }
    }
    private func titleField(_ prompt: LocalizedStringKey, key: String) -> some View {
        let text = Binding(get: {model.edit.settings[key]?.string ?? ""}, set: {model.edit.settings[key] = .text(String($0.prefix(Edit.titleLimit)))})
        return TextField(prompt, text: text)
            .font(RK.font(15)).foregroundStyle(RK.ink).submitLabel(.done)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A post caption, ready to paste under the movie.
private struct CaptionRow: View {
    let caption: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("כיתוב לפוסט").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            Text(verbatim: caption).font(RK.font(14)).foregroundStyle(RK.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Button {UIPasteboard.general.string = caption; copied = true} label: {
                Label(copied ? LocalizedStringKey("הועתק") : LocalizedStringKey("העתקת הכיתוב"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .font(RK.font(13, 500, style: .footnote)).buttonStyle(.plain).foregroundStyle(RK.accent)
        }
        .onChange(of: caption) {copied = false}
        .accessibilityIdentifier("export.caption")
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
                    // The caption rides along: it is on the clipboard by the time the post is written.
                    ShareLink(item: movie) {Label("שיתוף", systemImage: "square.and.arrow.up")}.buttonStyle(SecondaryButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded {if let caption, !caption.isEmpty {UIPasteboard.general.string = caption}})
                    Button(action: backToEdit) {Label("חזרה לעריכה", systemImage: "slider.horizontal.3")}.buttonStyle(SecondaryButtonStyle())
                    if let current {
                        Menu {
                            Button(role: .destructive) {Task {await model.deleteExport(current)}} label: {Label("מחיקת הסרט", systemImage: "trash")}
                        } label: {Image(systemName: "ellipsis")}
                        .buttonStyle(IconButtonStyle()).accessibilityLabel("עוד פעולות על הסרט")
                    }
                }.disabled(model.busy).rkRow()
                if let caption, !caption.isEmpty {
                    CaptionRow(caption: caption).rkCard(padding: 16).rkRow()
                    Text("הכיתוב מועתק לבד כשמשתפים, מוכן להדבקה.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.faint).rkRow(top: 0)
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
        // The finished movie plays as soon as it is ready.
        .onAppear {player = model.movieURL.map(AVPlayer.init(url:)); player?.play()}
        .onChange(of: model.movieURL) {_, movie in player?.pause(); player = movie.map(AVPlayer.init(url:)); player?.play()}
        .onDisappear {player?.pause()}
    }
    private var current: LocalExport? {model.project?.exports.first {$0.file == model.movieURL?.lastPathComponent}}
    private var caption: String? {model.edit.settings["caption"]?.string}
    private var earlier: [LocalExport] {(model.project?.exports ?? []).filter {$0.file != model.movieURL?.lastPathComponent}.reversed()}
    private func play(_ result: LocalExport) {
        guard let project = model.project else {return}
        model.movieURL = LocalStore.file(result.file, project: project.id)
    }
}
