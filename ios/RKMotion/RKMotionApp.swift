import SwiftUI
import PhotosUI
import AVKit
import VisionKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == Transfers.sessionID else {completionHandler(); return}
        Transfers.shared.backgroundCompletion = completionHandler
        Task {@MainActor in await Transfers.shared.resumeAll()}
    }
}

@main struct RKMotionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {WindowGroup {EditorView().environment(\.layoutDirection, .rightToLeft)}}
}

struct EditorView: View {
    @StateObject private var model = EditorModel()
    @StateObject private var transfers = Transfers.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var pairingLink = ""
    @State private var selectedVideo: PhotosPickerItem?
    @State private var showScanner = false
    @State private var showImporter = false
    @State private var importingMusic = false
    @State private var confirmDelete = false
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("מהרכיבה לרגעים הטובים").font(.title2.bold())
                        Text("העריכה באייפון. העיבוד הפרטי במק שלכם.").foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                if !model.connected {connectionSection}
                else {
                    importSection
                    if !transfers.records.isEmpty || !transfers.message.isEmpty {
                        Section("העברת קבצים") {
                            ProgressView(value: transfers.progress)
                            Text(transfers.message).font(.footnote)
                            if !transfers.records.isEmpty {
                                Button("המשך העלאות שנעצרו") {Task {await transfers.resumeAll()}}
                            }
                        }
                    }
                    if model.busy {Section("עיבוד במק") {ProgressView(value: model.percent, total: 100); Text(model.message).font(.footnote)}}
                    if let report = model.report {
                        Section("תצוגה מקדימה") {
                            if let player {VideoPlayer(player: player).frame(height: 220)}
                            Button("הורדת תצוגה מקדימה") {model.preview()}
                            Text("משך המקור: \(Int(report.duration)) שניות").font(.caption).foregroundStyle(.secondary)
                        }
                        clipsSection
                        optionsSection
                        Section {
                            Button {Task {await model.exportMovie()}} label: {Label("ייצוא הסרט במק", systemImage: "film.stack")}
                                .disabled(model.busy || model.edit.clips.allSatisfy {$0.selected == false} || !transfers.records.isEmpty)
                            HStack {
                                Button("ביטול שינוי") {model.undo()}.disabled(!model.undoAvailable || model.busy)
                                Spacer()
                                Button("שחזור שינוי") {model.redo()}.disabled(!model.redoAvailable || model.busy)
                            }
                        }
                    }
                    if !model.exports.isEmpty {
                        Section("סרטים מוכנים") {
                            ForEach(model.exports.reversed()) {result in
                                Button("הורדת גרסה \(result.version) · \(Int(result.duration)) שניות") {
                                    do {try transfers.download(result.download)} catch {model.message = error.localizedDescription}
                                }
                            }
                        }
                    }
                    if let movie = transfers.movieURL {
                        Section("שמירה ושיתוף") {
                            Button("שמירת הסרט בתמונות") {Task {await model.saveToPhotos(movie)}}
                            ShareLink(item: movie) {Label("שיתוף קובץ הסרט", systemImage: "square.and.arrow.up")}
                            Button("ניגון הסרט שהורד") {player = AVPlayer(url: movie)}
                        }
                    }
                    if !model.projects.isEmpty {
                        Section("פרויקטים שמורים במק") {
                            ForEach(model.projects) {project in
                                Button {
                                    Task {await model.openProject(project.job_id)}
                                } label: {
                                    HStack {
                                        Text(project.created.map {Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)} ?? project.job_id)
                                        Spacer(); Image(systemName: project.job_id == model.activeJob ? "checkmark.circle.fill" : "folder")
                                    }
                                }.disabled(model.busy || !transfers.records.isEmpty)
                            }
                        }
                    }
                    Section {
                        Button("רענון וחיבור מחדש") {Task {await model.reconnect()}}.disabled(model.busy)
                        if model.activeJob != nil {Button("מחיקת הפרויקט", role: .destructive) {confirmDelete = true}}
                        Button("ניתוק מהמק", role: .destructive) {model.disconnect()}
                    }
                }
                if !model.message.isEmpty && !model.busy {Section {Text(model.message).font(.footnote).textSelection(.enabled)}}
            }
            .navigationTitle("RK Motion")
            .toolbar {if model.report != nil {EditButton().disabled(model.busy)}}
            .tint(Color(red: 0.20, green: 0.69, blue: 0.47))
            .task {if model.connected {await model.reconnect()}}
            .onChange(of: model.edit) {previous, _ in model.changed(from: previous)}
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
            .onChange(of: transfers.previewURL) {_, url in if let url {player = AVPlayer(url: url)}}
            .onChange(of: scenePhase) {_, phase in
                if phase == .active && model.connected {Task {await model.reconnect()}}
                else if phase == .background {model.pause()}
            }
            .onReceive(NotificationCenter.default.publisher(for: .rkUploadFinished)) {event in
                guard let job = event.userInfo?["job"] as? String, let kind = event.userInfo?["kind"] as? String else {return}
                Task {await model.uploadFinished(job: job, kind: kind)}
            }
            .sheet(isPresented: $showScanner) {
                QRScanner {link in showScanner = false; pairingLink = link; Task {await model.pair(link)}}
                    .overlay(alignment: .topLeading) {Button("סגירה") {showScanner = false}.padding().background(.regularMaterial)}
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importingMusic ? [.audio] : [.movie]) {result in
                do {
                    let source = try result.get()
                    let access = source.startAccessingSecurityScopedResource()
                    defer {if access {source.stopAccessingSecurityScopedResource()}}
                    let target = TransferStore.directory("imports").appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
                    try FileManager.default.copyItem(at: source, to: target)
                    let music = importingMusic
                    Task {if music {await model.importMusic(target)} else {await model.importVideo(target)}}
                } catch {model.message = error.localizedDescription}
            }
            .confirmationDialog("למחוק את הפרויקט ואת הסרטונים שלו במק?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("מחיקה", role: .destructive) {Task {await model.reset()}}
            }
        }
    }
    private var connectionSection: some View {
        Section("חיבור למק") {
            Text("הפעילו במק RK Motion עם ‎--lan ולחצו על חיבור לאייפון. שני המכשירים צריכים להיות באותה רשת.").font(.footnote)
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                Button("סריקת קוד החיבור") {showScanner = true}
            }
            TextField("הדבקת קישור הצימוד הפרטי", text: $pairingLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("חיבור") {Task {await model.pair(pairingLink)}}.disabled(pairingLink.isEmpty)
            Text("לא ניתן להתחבר למק חדש בלי קישור צימוד. התעודה מאומתת מול טביעת האצבע בקוד.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var importSection: some View {
        Section("בחירת סרטון") {
            Toggle("הסרטון כבר ערוך — להשאיר אותו שלם", isOn: $model.wholeVideo)
            PhotosPicker(selection: $selectedVideo, matching: .videos, preferredItemEncoding: .current) {Label("בחירה מתמונות", systemImage: "photo.on.rectangle")}
                .disabled(model.busy || !transfers.records.isEmpty)
            Button("בחירת סרטון מקבצים") {importingMusic = false; showImporter = true}.disabled(model.busy || !transfers.records.isEmpty)
        }
    }
    private var clipsSection: some View {
        Section("קטעי הסרט — גררו לשינוי סדר") {
            ForEach($model.edit.clips) {$clip in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("קטע \(Int(clip.start))–\(Int(clip.end)) שניות", isOn: Binding(get: {clip.selected != false}, set: {clip.selected = $0}))
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
                let start = min(playhead.isFinite ? max(0, playhead) : 0, max(0, (model.report?.duration ?? 0) - 1))
                var clip = Clip(start: max(0, start), end: min(model.report?.duration ?? 0, start + 5)); clip.manual = true
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
            Picker("מסגרת", selection: setting("aspect", fallback: "16:9")) {Text("מקור").tag("16:9"); Text("סטורי 9:16").tag("9:16")}
            Picker("מהירות", selection: setting("speed", fallback: "1")) {ForEach(["1", "1.25", "1.5", "2"], id: \.self) {Text($0 + "×").tag($0)}}
            Picker("מעבר", selection: setting("transition", fallback: "cut")) {
                Text("חיתוך").tag("cut"); Text("דהייה").tag("fade"); Text("המסה").tag("dissolve"); Text("ניגוב").tag("wipeleft"); Text("החלקה").tag("slideright")
            }
            Picker("משך המעבר", selection: setting("transitionDuration", fallback: "0.5")) {ForEach(["0.3", "0.5", "1"], id: \.self) {Text($0 + " שניות").tag($0)}}
            Toggle("הסרת שמע הרכיבה", isOn: Binding(get: {model.edit.settings["muteOriginal"]?.bool ?? false}, set: {model.edit.settings["muteOriginal"] = .flag($0)}))
            Button("הוספת מוזיקה מקבצים") {importingMusic = true; showImporter = true}
            if !model.music.isEmpty {
                Toggle("שימוש במוזיקה", isOn: $model.useMusic)
                ForEach(model.music.indices, id: \.self) {Text(model.music[$0].name).font(.caption)}
                TextField("התחלה במוזיקה — שניות", text: setting("musicStart", fallback: "0")).keyboardType(.decimalPad)
                Picker("עוצמת מוזיקה", selection: setting("musicVolume", fallback: "0.65")) {Text("רקע").tag("0.35"); Text("מאוזן").tag("0.65"); Text("חזק").tag("1")}
            }
        }.disabled(model.busy)
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    func makeCoordinator() -> Coordinator {Coordinator(scanned)}
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {controller.stopScanning()}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let callback: (String) -> Void
        var finished = false
        init(_ callback: @escaping (String) -> Void) {self.callback = callback}
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else {return}
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    finished = true; scanner.stopScanning(); callback(value); return
                }
            }
        }
    }
}
