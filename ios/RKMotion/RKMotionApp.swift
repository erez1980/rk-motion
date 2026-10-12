import SwiftUI
import UIKit
import PhotosUI
import AVKit
import UniformTypeIdentifiers

@main struct RKMotionApp: App {
    var body: some Scene {WindowGroup {EditorView().environment(\.layoutDirection, .rightToLeft)}}
}
struct EditorView: View {
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedVideo: PhotosPickerItem?
    @State private var showImporter = false
    @State private var importingMusic = false
    @State private var confirmDelete = false
    @State private var player: AVPlayer?
    private struct TrimSelection: Identifiable {let id: String}
    @State private var trimming: TrimSelection?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("מהרכיבה לרגעים הטובים").font(.title2.bold())
                    Text("ניתוח, עריכה וייצוא — הכול באייפון שלכם.").foregroundStyle(.secondary)
                    Text(model.backgroundDescription).font(.caption).foregroundStyle(.secondary)
                }
                Section("בחירת סרטון") {
                    Toggle("הסרטון כבר ערוך — להשאיר אותו שלם", isOn: $model.wholeVideo)
                    if model.project?.analyzed == true {
                        Button("החלת מצב הבחירה על הפרויקט") {model.applyWholeVideo()}
                        Text("הפעולה מחליפה את הקטעים הנוכחיים; אפשר לבטל את השינוי.").font(.caption)
                    }
                    PhotosPicker(selection: $selectedVideo, matching: .videos, preferredItemEncoding: .current) {Label("בחירה מתמונות", systemImage: "photo.on.rectangle")}
                    Button("בחירת סרטון מקבצים") {importingMusic = false; showImporter = true}
                }.disabled(model.busy || selectedVideo != nil)
                if model.busy {
                    Section("עיבוד מקומי באייפון") {
                        ProgressView(value: model.percent, total: 100)
                            .accessibilityLabel("התקדמות העיבוד")
                            .accessibilityValue(String(format: NSLocalizedString("%@ אחוז", comment: "Progress percent"), "\(Int(model.percent))"))
                        Text(LocalizedStringKey(model.message)).font(.footnote)
                        Button("ביטול הפעולה") {model.cancel()}.disabled(!model.canCancel)
                    }
                }
                if let project = model.project {
                    Section("תצוגה מקדימה") {
                        if let player {VideoPlayer(player: player).frame(height: 220)}
                        Button("ניגון המקור") {player = model.sourceURL.map(AVPlayer.init(url:))}
                        if project.analyzed {
                            Button("תצוגה מקדימה של העריכה") {model.preview()}
                                .disabled(model.busy || model.edit.clips.allSatisfy {$0.selected == false} || model.editValidationMessage != nil)
                            Text("התצוגה כוללת חיתוכים, סדר, מהירות ומוזיקה ללא ייצוא קובץ.").font(.caption)
                        }
                        if project.duration > 0 {Text(String(format: NSLocalizedString("משך המקור: %@ שניות", comment: "Source length"), "\(Int(project.duration))")).font(.caption)}
                        if !project.analyzed {Button("ניתוח הסרטון באייפון") {model.analyze()}.disabled(model.busy)}
                    }
                    .disabled(model.busy)
                    if project.analyzed {
                        if !project.scores.isEmpty {
                            Section("רגישות זיהוי הפעילות") {
                                Slider(value: $model.threshold, in: 0.25...0.9, step: 0.05).accessibilityLabel("רגישות זיהוי הפעילות")
                                Button("הפקת הצעות מחדש") {model.retune()}
                                Text("הצעות הפעילות יוחלפו; ניתן לבטל את השינוי.").font(.caption).foregroundStyle(.secondary)
                            }.disabled(model.busy)
                        }
                        clipsSection
                        optionsSection
                        Section {
                            Text(model.exportSummary).font(.caption).foregroundStyle(.secondary)
                            if let problem = model.editValidationMessage {Text(problem).font(.caption).foregroundStyle(.red)}
                            Button {model.exportMovie()} label: {Label("ייצוא הסרט באייפון", systemImage: "film.stack")}
                                .disabled(model.busy || model.edit.clips.isEmpty || model.edit.clips.allSatisfy {$0.selected == false} || model.editValidationMessage != nil)
                            HStack {
                                Button("ביטול שינוי") {model.undo()}.disabled(!model.undoAvailable || model.busy)
                                Spacer(); Button("שחזור שינוי") {model.redo()}.disabled(!model.redoAvailable || model.busy)
                            }
                        }
                    }
                    if !project.exports.isEmpty {
                        Section("סרטים שנוצרו באייפון") {
                            ForEach(project.exports.reversed()) {result in
                                Button("סרט מ־" + result.created.formatted(date: .abbreviated, time: .shortened)) {
                                    model.movieURL = LocalStore.file(result.file, project: project.id)
                                    player = AVPlayer(url: model.movieURL!)
                                }.swipeActions {
                                    Button("מחיקת הסרט", role: .destructive) {player?.pause(); player = nil; Task {await model.deleteExport(result)}}
                                        .disabled(model.busy)
                                }
                            }
                        }
                    }
                    if let movie = model.movieURL {
                        Section("שמירה ושיתוף") {
                            Button("שמירת הסרט בתמונות") {Task {await model.saveToPhotos(movie)}}
                            ShareLink(item: movie) {Label("שיתוף קובץ הסרט", systemImage: "square.and.arrow.up")}
                            Button("ניגון הסרט הערוך") {player = AVPlayer(url: movie)}
                        }.disabled(model.busy)
                    }
                    Section("אחסון מקומי") {
                        Text("נפח הפרויקט: " + ByteCountFormatter.string(fromByteCount: model.projectBytes, countStyle: .file))
                        Button("ניקוי קבצים זמניים שנותרו") {Task {await model.cleanTemporaryFiles()}}.disabled(model.busy)
                        Text("מחיקת סרט שנוצר אינה מוחקת את המקור או את העריכה. עותקים שנשמרו בתמונות אינם נמחקים.").font(.caption)
                    }
                    Section {Button("מחיקת הפרויקט מהאייפון", role: .destructive) {confirmDelete = true}.disabled(model.busy)}
                }
                if !model.message.isEmpty && !model.busy {
                    Section {
                        Text(LocalizedStringKey(model.message)).font(.footnote).textSelection(.enabled)
                        if model.photoPermissionDenied {
                            Button("פתיחת הגדרות הרשאת תמונות") {if let url = URL(string: UIApplication.openSettingsURLString) {UIApplication.shared.open(url)}}
                        }
                        if model.saveFailed {Button("ניסיון חוזר לשמירת הפרויקט") {Task {_ = await model.save()}}}
                    }
                }
            }
            .navigationTitle("RK Motion")
            .toolbar {
                if model.project?.analyzed == true {EditButton().disabled(model.busy)}
                NavigationLink {ProjectLibraryView(model: model)} label: {Label("פרויקטים", systemImage: "square.grid.2x2")}
                NavigationLink {AboutView()} label: {Label("עזרה", systemImage: "questionmark.circle")}
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {Spacer(); Button("בוצע") {UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)}}
            }
            .tint(Color(red: 0.20, green: 0.69, blue: 0.47))
            .task {await model.restore()}
            .onChange(of: model.edit) {previous, _ in model.changed(from: previous)}
            .onChange(of: model.previewItem) {_, item in
                if let item {player = AVPlayer(playerItem: item)}
                else if player?.currentItem?.asset is AVComposition {player?.pause(); player = model.sourceURL.map(AVPlayer.init(url:))}
            }
            .onChange(of: model.project?.id) {_, _ in player = model.sourceURL.map(AVPlayer.init(url:))}
            .onChange(of: selectedVideo) {_, item in
                guard let item else {return}
                model.importPickedVideo(item)
                selectedVideo = nil
            }
            .onChange(of: scenePhase) {_, phase in
                if phase == .background {player?.pause(); model.pause()}
                else if phase == .active {model.foreground()}
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importingMusic ? [.audio] : [.movie]) {result in
                switch result {
                case .success(let source):
                    let music = importingMusic
                    Task {if music {await model.importMusic(source)} else {await model.importVideo(source)}}
                case .failure(let error): model.message = error.localizedDescription
                }
            }
            .sheet(item: $trimming) {selection in
                if let index = model.edit.clips.firstIndex(where: {$0.id == selection.id}),
                   let source = model.sourceURL, let duration = model.project?.duration, duration > 0.01 {
                    ClipTrimView(clip: $model.edit.clips[index], source: source, duration: duration)
                }
            }
            .confirmationDialog("למחוק את הפרויקט ואת הקבצים שלו מהאייפון?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("מחיקה", role: .destructive) {player?.pause(); player = nil; Task {await model.reset()}}
            }
        }
    }
    private var clipsSection: some View {
        Section("קטעי הסרט — גררו לשינוי סדר") {
            ForEach($model.edit.clips) {$clip in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(String(format: NSLocalizedString("קטע %@–%@ שניות", comment: "Clip range toggle"), "\(Int(clip.start.isFinite ? clip.start : 0))", "\(Int(clip.end.isFinite ? clip.end : 0))"), isOn: Binding(get: {clip.selected != false}, set: {clip.selected = $0}))
                    if (model.project?.duration ?? 0) > 0.01 {
                        Button("תצוגה וחיתוך הקטע") {trimming = TrimSelection(id: clip.id)}
                            .accessibilityLabel(String(format: NSLocalizedString("תצוגה וחיתוך קטע שמתחיל ב־%@ שניות", comment: "Trim button label"), "\(Int(clip.start.isFinite ? clip.start : 0))"))
                    }
                    DisclosureGroup("הזנת זמנים מדויקת") {
                      HStack {
                        Text("התחלה")
                        TextField("שניות", value: $clip.start, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).accessibilityLabel("תחילת הקטע בשניות")
                        Text("סיום")
                        TextField("שניות", value: $clip.end, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad).accessibilityLabel("סיום הקטע בשניות")
                      }.font(.footnote)
                    }
                    if let score = clip.score {Text(String(format: NSLocalizedString("ציון פעילות: %@%%", comment: "Activity score"), "\(Int(score * 100))")).font(.caption).foregroundStyle(.secondary)}
                }.disabled(model.busy)
            }.onMove {if !model.busy {model.edit.clips.move(fromOffsets: $0, toOffset: $1)}}
             .onDelete {if !model.busy {model.edit.clips.remove(atOffsets: $0)}}
            Button("הוספת קטע ידני") {
                // Edited-preview time is not a timestamp in the original.
                let playhead = player?.currentItem?.asset is AVComposition ? 0 : (player?.currentTime().seconds ?? 0)
                let start = min(playhead.isFinite ? max(0, playhead) : 0, max(0, (model.project?.duration ?? 0) - 1))
                var clip = Clip(start: max(0, start), end: min(model.project?.duration ?? 0, start + 5)); clip.manual = true
                model.edit.clips.append(clip)
            }.disabled(model.busy)
        }
    }
    private func setting(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: {model.edit.settings[key]?.string ?? fallback}, set: {model.edit.settings[key] = .text($0)})
    }
    private var optionsSection: some View {
        Section("אפשרויות ייצוא") {
            Picker("איכות מרבית", selection: setting("quality", fallback: "1080")) {
                Text("1080p").tag("1080"); Text("720p").tag("720"); Text("רזולוציית מקור").tag("original"); Text("WhatsApp").tag("whatsapp")
            }
            Text("כל הייצואים הם SDR ב־30fps. רזולוציית מקור אינה שימור HDR או ייצוא ללא אובדן.").font(.caption).foregroundStyle(.secondary)
            Picker("מסגרת", selection: setting("aspect", fallback: "source")) {Text("מקור").tag("source"); Text("סטורי 9:16").tag("9:16")}
            Picker("מהירות", selection: setting("speed", fallback: "1")) {ForEach(["1", "1.25", "1.5", "2"], id: \.self) {Text($0 + "×").tag($0)}}
            Picker("מעבר", selection: setting("transition", fallback: "cut")) {
                Text("חיתוך").tag("cut"); Text("המסה").tag("dissolve")
            }
            Picker("משך המעבר", selection: setting("transitionDuration", fallback: "0.5")) {ForEach(["0.3", "0.5", "1"], id: \.self) {Text(String(format: NSLocalizedString("%@ שניות", comment: "Seconds value"), $0)).tag($0)}}
            Toggle("הסרת שמע הרכיבה", isOn: Binding(get: {model.edit.settings["muteOriginal"]?.bool ?? false}, set: {model.edit.settings["muteOriginal"] = .flag($0)}))
            Button("הוספת מוזיקה מקבצים") {importingMusic = true; showImporter = true}
            if let songs = model.project?.music, !songs.isEmpty {
                Toggle("שימוש במוזיקה", isOn: Binding(get: {model.edit.settings["useMusic"]?.bool ?? true}, set: {model.edit.settings["useMusic"] = .flag($0)}))
                ForEach(songs) {song in
                    HStack {Text(song.name).font(.caption); Spacer(); Button("הסרה") {Task {await model.removeMusic(song.id)}}}
                }
                TextField("התחלה במוזיקה — שניות", text: setting("musicStart", fallback: "0")).keyboardType(.decimalPad)
                Picker("עוצמת מוזיקה", selection: setting("musicVolume", fallback: "0.65")) {Text("רקע").tag("0.35"); Text("מאוזן").tag("0.65"); Text("חזק").tag("1")}
            }
        }.disabled(model.busy)
    }
}
