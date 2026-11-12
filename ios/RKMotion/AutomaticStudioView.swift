import SwiftUI
import UniformTypeIdentifiers

/// Every button performs an operation immediately with automatic defaults.
/// Optional inspection never blocks producing the movie. Actions that make or
/// change the movie close the sheet; upkeep actions stay and answer in it.
struct AutomaticStudioView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false
    var body: some View {
        NavigationStack {
            List {
                Text("לחיצה אחת: בחירת רגעים, מוזיקה מקומית, מסגור, בדיקה וייצוא. אין צורך להקליד או לכוון הגדרות.")
                    .font(RK.font(14)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true).rkRow(top: 4)
                header("סרטים אוטומטיים")
                ForEach(AutomaticStyle.allCases) {style in
                    row(style.title, detail: style.detail, symbol: style.symbol, id: "automatic.make." + style.rawValue, closes: true) {model.automaticMovie(style: style)}
                }
                row(NSLocalizedString("שלושה סיפורים אוטומטיים", comment: "Automatic studio action"), detail: NSLocalizedString("אקשן, קולנועי ומשפחתי, מאותם הצילומים", comment: "Automatic studio action detail"),
                    symbol: "square.stack.3d.up", id: "automatic.stories", closes: true) {model.automaticMovie(allStories: true)}
                header("השוואה וזוויות")
                row(NSLocalizedString("סרט קבוצתי אוטומטי", comment: "Automatic studio action"), detail: NSLocalizedString("מחבר צילום מקביל מפרויקט אחר לפי הקול המשותף", comment: "Automatic studio action detail"),
                    symbol: "video.badge.waveform", id: "automatic.multicam", closes: true,
                    unavailable: hasOtherProjects ? nil : NSLocalizedString("צריך עוד פרויקט באייפון שצולם באותו זמן.", comment: "Why multicam is unavailable")) {model.automaticMulticam()}
                row(NSLocalizedString("השוואה לצילום קודם באותו מקום", comment: "Automatic studio action"), detail: NSLocalizedString("מוצא בפרויקט אחר את הפריים הדומה ומציג את שניהם זה לצד זה", comment: "Automatic studio action detail"),
                    symbol: "rectangle.split.2x1", id: "automatic.compare", closes: true,
                    unavailable: hasAnalyzedProjects ? nil : NSLocalizedString("צריך עוד פרויקט מנותח באייפון.", comment: "Why comparison is unavailable")) {model.automaticComparison()}
                header("גיבוי ושחזור")
                row(NSLocalizedString("חזרה לגרסה הקודמת", comment: "Automatic studio action"), detail: NSLocalizedString("העריכה הקודמת שנשמרה, גם אחרי סגירת האפליקציה", comment: "Automatic studio action detail"),
                    symbol: "clock.arrow.circlepath", id: "automatic.restoreVersion", closes: true,
                    unavailable: hasPreviousVersion ? nil : NSLocalizedString("עדיין אין גרסה קודמת לשחזור.", comment: "No persistent version")) {model.automaticRestoreVersion()}
                row(NSLocalizedString("בדיקה שאפשר לעבוד בלי רשת", comment: "Automatic studio action"), detail: NSLocalizedString("שהמקורות, המוזיקה והמקום הפנוי כולם באייפון", comment: "Automatic studio action detail"),
                    symbol: "airplane", id: "automatic.check", closes: false) {model.automaticCheck()}
                row(NSLocalizedString("גיבוי הפרויקט", comment: "Automatic studio action"), detail: NSLocalizedString("קובץ ZIP עם המקורות, המוזיקה והעריכה, לשמירה או לשיתוף", comment: "Automatic studio action detail"),
                    symbol: "archivebox", id: "automatic.archive", closes: false) {model.automaticArchive()}
                if let package = model.automaticPackage {
                    ShareLink(item: package) {Label("שיתוף גיבוי הפרויקט", systemImage: "square.and.arrow.up")}
                        .font(RK.font(15, 500)).foregroundStyle(RK.accent).rkRow(top: 0)
                }
                row(NSLocalizedString("שחזור פרויקט מגיבוי", comment: "Automatic studio action"), detail: NSLocalizedString("פותח גיבוי כפרויקט חדש, בלי לדרוס פרויקט קיים", comment: "Automatic studio action detail"),
                    symbol: "arrow.down.doc", id: "automatic.restorePackage", closes: false) {restoring = true}
                Group {
                    if model.busy {ProgressCard(model: model)}
                    MessageCard(model: model)
                }.rkRow()
            }
            .rkScreen()
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
    private var hasOtherProjects: Bool {model.projects.contains {$0.id != model.project?.id}}
    private var hasAnalyzedProjects: Bool {model.projects.contains {$0.id != model.project?.id && $0.analyzed}}
    private var hasPreviousVersion: Bool {
        guard let p = model.project else {return false}
        return AutomaticStore.versions(p.id).contains {$0.edit != model.edit}
    }
    private func header(_ title: LocalizedStringKey) -> some View {
        Text(title).font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.soft).rkRow(top: 14, bottom: 2)
    }
    /// One action: its name, what it does, and why it cannot run now when it cannot.
    private func row(_ title: String, detail: String, symbol: String, id: String, closes: Bool, unavailable: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            if closes {dismiss()}
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(unavailable == nil ? RK.accent : RK.faint)
                    .frame(width: 40, height: 40).background(RK.accentSoft, in: RoundedRectangle(cornerRadius: RK.Radius.small, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(RK.font(15, 500)).foregroundStyle(RK.ink)
                    Text(verbatim: unavailable ?? detail).font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10).background(RK.card, in: RoundedRectangle(cornerRadius: RK.Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy || unavailable != nil)
        .accessibilityIdentifier(id)
        .rkRow(top: 3, bottom: 3)
    }
}

/// The one-tap movie, as the primary button of the steps before the music.
struct AutomaticMovieButton: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Button {model.automaticMovie()} label: {
            Label("צור לי סרט", systemImage: "sparkles").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.busy)
        .accessibilityIdentifier("automatic.make")
    }
}
