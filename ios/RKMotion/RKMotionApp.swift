import SwiftUI
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
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("מהרכיבה לרגעים הטובים").font(.title2.bold())
                    Text("ניתוח, עריכה וייצוא — הכול באייפון שלכם.").foregroundStyle(.secondary)
                    Text("לסרטונים ארוכים השאירו את האפליקציה פתוחה בזמן העיבוד.").font(.caption).foregroundStyle(.secondary)
                }
                Section("בחירת סרטון") {
                    Toggle("הסרטון כבר ערוך — להשאיר אותו שלם", isOn: $model.wholeVideo)
                    PhotosPicker(selection: $selectedVideo, matching: .videos, preferredItemEncoding: .current) {Label("בחירה מתמונות", systemImage: "photo.on.rectangle")}
                    Button("בחירת סרטון מקבצים") {importingMusic = false; showImporter = true}
                }.disabled(model.busy || selectedVideo != nil)
                if model.busy {
                    Section("עיבוד מקומי באייפון") {
                        ProgressView(value: model.percent, total: 100)
                        Text(model.message).font(.footnote)
                        Button("ביטול הפעולה") {model.cancel()}.disabled(!model.canCancel)
                    }
                }
                if let project = model.project {
                    Section("תצוגה מקדימה") {
                        if let player {VideoPlayer(player: player).frame(height: 220)}
                        Button("ניגון המקור") {player = model.sourceURL.map(AVPlayer.init(url:))}
                        if project.duration > 0 {Text("משך המקור: \(Int(project.duration)) שניות").font(.caption)}
                        if !project.analyzed {Button("ניתוח הסרטון באייפון") {model.analyze()}.disabled(model.busy)}
                    }
                    if project.analyzed {
                        if !project.scores.isEmpty {
                            Section("רגישות זיהוי הפעילות") {
                                Slider(value: $model.threshold, in: 0.25...0.9, step: 0.05)
                                Button("הפקת הצעות מחדש") {model.retune()}
                                Text("הצעות הפעילות יוחלפו; ניתן לבטל את השינוי.").font(.caption).foregroundStyle(.secondary)
                            }.disabled(model.busy)
                        }
                        clipsSection
                        optionsSection
                        Section {
                            Button {model.exportMovie()} label: {Label("ייצוא הסרט באייפון", systemImage: "film.stack")}
                                .disabled(model.busy || model.edit.clips.isEmpty || model.edit.clips.allSatisfy {$0.selected == false})
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
                                }
                            }
                        }
                    }
                    if let movie = model.movieURL {
                        Section("שמירה ושיתוף") {
                            Button("שמירת הסרט בתמונות") {Task {await model.saveToPhotos(movie)}}
                            ShareLink(item: movie) {Label("שיתוף קובץ הסרט", systemImage: "square.and.arrow.up")}
                            Button("ניגון הסרט הערוך") {player = AVPlayer(url: movie)}
                        }
                    }
                    Section {Button("מחיקת הפרויקט מהאייפון", role: .destructive) {confirmDelete = true}.disabled(model.busy)}
                }
                if !model.projects.isEmpty {
                    Section("פרויקטים שמורים באייפון") {
                        ForEach(model.projects) {project in
                            Button {model.open(project)} label: {
                                VStack(alignment: .leading) {
                                    Text(project.name).lineLimit(1)
                                    Text(project.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(model.busy)
                        }
                    }
                }
                if !model.message.isEmpty && !model.busy {Section {Text(model.message).font(.footnote).textSelection(.enabled)}}
            }
            .navigationTitle("RK Motion")
            .toolbar {
                if model.project?.analyzed == true {EditButton().disabled(model.busy)}
                NavigationLink {AboutView()} label: {Label("עזרה", systemImage: "questionmark.circle")}
            }
            .tint(Color(red: 0.20, green: 0.69, blue: 0.47))
            .task {model.restore()}
            .onChange(of: model.edit) {previous, _ in model.changed(from: previous)}
            .onChange(of: model.project?.id) {_, _ in player = model.sourceURL.map(AVPlayer.init(url:))}
            .onChange(of: selectedVideo) {_, item in
                guard let item else {return}
                Task {
                    do {
                        model.message = "האייפון מכין את הקובץ…"
                        if let picked = try await item.loadTransferable(type: PickedMovie.self) {await model.importVideo(picked.url)}
                    } catch {model.message = error.localizedDescription}
                    selectedVideo = nil
                }
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
            .confirmationDialog("למחוק את הפרויקט ואת הקבצים שלו מהאייפון?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("מחיקה", role: .destructive) {model.reset()}
            }
        }
    }
    private var clipsSection: some View {
        Section("קטעי הסרט — גררו לשינוי סדר") {
            ForEach($model.edit.clips) {$clip in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("קטע \(Int(clip.start.isFinite ? clip.start : 0))–\(Int(clip.end.isFinite ? clip.end : 0)) שניות", isOn: Binding(get: {clip.selected != false}, set: {clip.selected = $0}))
                    HStack {
                        Text("התחלה")
                        TextField("שניות", value: $clip.start, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad)
                        Text("סיום")
                        TextField("שניות", value: $clip.end, format: .number.precision(.fractionLength(0...2))).keyboardType(.decimalPad)
                    }.font(.footnote)
                    if let score = clip.score {Text("ציון פעילות: \(Int(score * 100))%").font(.caption).foregroundStyle(.secondary)}
                }.disabled(model.busy)
            }.onMove {model.edit.clips.move(fromOffsets: $0, toOffset: $1)}
             .onDelete {model.edit.clips.remove(atOffsets: $0)}
            Button("הוספת קטע ידני") {
                let playhead = player?.currentTime().seconds ?? 0
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
                Text("1080p").tag("1080"); Text("720p").tag("720"); Text("מקור").tag("original"); Text("WhatsApp").tag("whatsapp")
            }
            Picker("מסגרת", selection: setting("aspect", fallback: "source")) {Text("מקור").tag("source"); Text("סטורי 9:16").tag("9:16")}
            Picker("מהירות", selection: setting("speed", fallback: "1")) {ForEach(["1", "1.25", "1.5", "2"], id: \.self) {Text($0 + "×").tag($0)}}
            Picker("מעבר", selection: setting("transition", fallback: "cut")) {
                Text("חיתוך").tag("cut"); Text("המסה").tag("dissolve")
            }
            Picker("משך המעבר", selection: setting("transitionDuration", fallback: "0.5")) {ForEach(["0.3", "0.5", "1"], id: \.self) {Text($0 + " שניות").tag($0)}}
            Toggle("הסרת שמע הרכיבה", isOn: Binding(get: {model.edit.settings["muteOriginal"]?.bool ?? false}, set: {model.edit.settings["muteOriginal"] = .flag($0)}))
            Button("הוספת מוזיקה מקבצים") {importingMusic = true; showImporter = true}
            if let songs = model.project?.music, !songs.isEmpty {
                Toggle("שימוש במוזיקה", isOn: Binding(get: {model.edit.settings["useMusic"]?.bool ?? true}, set: {model.edit.settings["useMusic"] = .flag($0)}))
                ForEach(songs) {song in
                    HStack {Text(song.name).font(.caption); Spacer(); Button("הסרה") {model.removeMusic(song.id)}}
                }
                TextField("התחלה במוזיקה — שניות", text: setting("musicStart", fallback: "0")).keyboardType(.decimalPad)
                Picker("עוצמת מוזיקה", selection: setting("musicVolume", fallback: "0.65")) {Text("רקע").tag("0.35"); Text("מאוזן").tag("0.65"); Text("חזק").tag("1")}
            }
        }.disabled(model.busy)
    }
}
