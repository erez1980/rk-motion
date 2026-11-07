import SwiftUI
import UniformTypeIdentifiers

/// Every button performs an operation immediately with automatic defaults.
/// Optional inspection never blocks producing the movie.
struct AutomaticStudioView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false
    var body: some View {
        NavigationStack {
            List {
                Text("לחיצה אחת: בחירת רגעים, מוזיקה מקומית, מסגור, בדיקה וייצוא. אין צורך להקליד או לכוון הגדרות.")
                    .font(RK.font(15)).foregroundStyle(RK.soft)
                Group {
                ForEach(AutomaticStyle.allCases) {style in
                    Button {model.automaticMovie(style: style); dismiss()} label: {
                        Label {Text(verbatim: style.title)} icon: {Image(systemName: style.symbol)}
                    }
                    .accessibilityIdentifier("automatic.make." + style.rawValue)
                }
                Button {model.automaticMovie(allStories: true); dismiss()} label: {Label("שלושה סיפורים אוטומטיים", systemImage: "square.stack.3d.up")}
                    .accessibilityIdentifier("automatic.stories")
                Button {model.automaticMulticam(); dismiss()} label: {Label("סרט קבוצתי אוטומטי", systemImage: "video.badge.waveform")}
                    .accessibilityIdentifier("automatic.multicam")
                Button {model.automaticComparison(); dismiss()} label: {Label("השווה ניסיון אוטומטית", systemImage: "rectangle.split.2x1")}
                    .accessibilityIdentifier("automatic.compare")
                Button {model.automaticRestoreVersion(); dismiss()} label: {Label("חזור לגרסה הקודמת", systemImage: "clock.arrow.circlepath")}
                Button {model.automaticCheck()} label: {Label("בדוק מוכנות לשטח", systemImage: "airplane")}
                Button {model.automaticArchive()} label: {Label("גבה את הפרויקט", systemImage: "archivebox")}
                    .accessibilityIdentifier("automatic.archive")
                Button {restoring = true} label: {Label("שחזר גיבוי פרויקט", systemImage: "arrow.down.doc")}
                if let package = model.automaticPackage {
                    ShareLink(item: package) {Label("שיתוף גיבוי הפרויקט", systemImage: "square.and.arrow.up")}
                }
                }.disabled(model.busy)
                if let run = model.automaticRun {
                    Section {
                        Text(verbatim: String(format: NSLocalizedString("נבדקו %@ רגעים; %@ קטעים נבחרו.", comment: "Automatic run summary"), "\(run.events.count)", "\(run.review.selectedEvents)"))
                        ForEach(run.events.filter {event in run.edit.clips.contains {$0.uid == event.id}}.prefix(8)) {event in
                            HStack {
                                Text(verbatim: event.title)
                                Spacer()
                                Text(verbatim: RK.clock(event.start) + "–" + RK.clock(event.end)).monospacedDigit().foregroundStyle(RK.soft)
                            }
                        }
                    } header: {Text("על מה הסתמכתי")}
                }
                if let p = model.project, let report = AutomaticStore.read(AutomaticInsights.Report.self, name: "automatic-insights.json", project: p.id) {
                    Text(verbatim: report.nextShot).font(RK.font(14)).foregroundStyle(RK.soft)
                    ShareLink(item: LocalStore.file("automatic-source-notes.txt", project: p.id)) {Label("שיתוף הסיפור והמקורות", systemImage: "text.document")}
                }
                MessageCard(model: model)
                if model.busy {ProgressCard(model: model)}
            }
            .navigationTitle("סטודיו אוטומטי")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement: .confirmationAction) {Button("בוצע") {dismiss()}}}
        }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.zip]) {result in
            if case .success(let file) = result {model.automaticRestorePackage(file); dismiss()}
        }
        .tint(RK.accent)
        .environment(\.layoutDirection, AppLanguage.direction)
    }
}

struct AutomaticMovieButton: View {
    @ObservedObject var model: EditorModel
    @State private var studio = false
    var body: some View {
        HStack(spacing: 8) {
            Button {model.automaticMovie()} label: {
                Label("צור לי סרט", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("automatic.make")
            Button {studio = true} label: {Image(systemName: "square.grid.2x2").frame(width: 44, height: 44)}
                .buttonStyle(.plain).foregroundStyle(RK.accent)
                .accessibilityLabel("סטודיו אוטומטי").accessibilityIdentifier("automatic.studio")
        }
        .disabled(model.busy)
        .padding(.horizontal, 20).padding(.bottom, 8)
        .sheet(isPresented: $studio) {AutomaticStudioView(model: model)}
    }
}
