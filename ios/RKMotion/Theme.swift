import SwiftUI
import UIKit
import CoreText

/// The web app's colours, so the phone and the Mac look like one product.
/// Night is the brand; day follows the web app's light theme.
enum RK {
    enum UI {
        static let bg = pair(0x0a0d0b, 0xf4f8f3)
        static let card = pair(0x141a15, 0xffffff)
        static let raised = pair(0x1b231c, 0xeef4ec)
        static let ink = pair(0xf0f6f0, 0x17211a)
        static let soft = pair(0x9fb4a7, 0x586b5e)
        static let faint = pair(0x6f8577, 0x7d8f82)
        static let line = pair(0x263029, 0xdce5da)
        static let accent = pair(0xc8f542, 0x3f6d0a)
        static let accentInk = pair(0x182505, 0xffffff)
        static let accentSoft = UIColor {$0.userInterfaceStyle == .light ? hex(0xe8f5cd) : hex(0xc8f542, alpha: 0.13)}
        static let accentSoftInk = pair(0xd9fb7e, 0x33530b)
        static let good = pair(0x3ddc84, 0x1e8a50)
        static let danger = pair(0xff7a6b, 0xb3261e)
        static let barIdle = pair(0x2a352d, 0xd5dfd3)
        static let barSkipped = pair(0x56702a, 0xb9d68a)
        private static func pair(_ dark: UInt32, _ light: UInt32) -> UIColor {
            UIColor {$0.userInterfaceStyle == .light ? hex(light) : hex(dark)}
        }
        private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
            UIColor(red: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
        }
    }
    static let bg = Color(uiColor: UI.bg)
    static let card = Color(uiColor: UI.card)
    static let raised = Color(uiColor: UI.raised)
    static let ink = Color(uiColor: UI.ink)
    static let soft = Color(uiColor: UI.soft)
    static let faint = Color(uiColor: UI.faint)
    static let line = Color(uiColor: UI.line)
    static let accent = Color(uiColor: UI.accent)
    static let accentInk = Color(uiColor: UI.accentInk)
    static let accentSoft = Color(uiColor: UI.accentSoft)
    static let accentSoftInk = Color(uiColor: UI.accentSoftInk)
    static let good = Color(uiColor: UI.good)
    static let danger = Color(uiColor: UI.danger)
    static let barIdle = Color(uiColor: UI.barIdle)
    static let barSkipped = Color(uiColor: UI.barSkipped)

    /// Rubik ships as one variable font, so a weight is a point on its axis
    /// rather than a separate face.
    static func uiFont(_ size: CGFloat, _ weight: CGFloat = 400, style: UIFont.TextStyle = .body) -> UIFont {
        let base = UIFont(name: "Rubik-Light", size: size)
            ?? UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: "Rubik"]), size: size)
        let font: UIFont
        if base.familyName == "Rubik" {
            let axis = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            font = UIFont(descriptor: base.fontDescriptor.addingAttributes([axis: [NSNumber(value: 0x77676874): weight]]), size: size)
        } else {
            font = .systemFont(ofSize: size, weight: weight >= 700 ? .bold : weight >= 500 ? .medium : .regular)
        }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font, maximumPointSize: size * 1.6)
    }
    static func font(_ size: CGFloat, _ weight: CGFloat = 400, style: UIFont.TextStyle = .body) -> Font {
        Font(uiFont(size, weight, style: style) as CTFont)
    }

    /// Minutes and seconds, the way a rider reads a clip on the timeline.
    static func clock(_ seconds: Double) -> String {
        let total = Int((seconds.isFinite ? max(0, seconds) : 0).rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }
    static func seconds(_ value: Double) -> String {
        String(format: NSLocalizedString("%@ שניות", comment: "Seconds value"), "\(Int((value.isFinite ? max(0, value) : 0).rounded()))")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RK.font(17, 700, style: .headline))
            .foregroundStyle(RK.accentInk)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RK.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RK.font(15, 500))
            .foregroundStyle(RK.ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(RK.line))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
/// A square icon button for the second action beside a primary one.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 56
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(RK.soft)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(RK.line))
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

extension View {
    func rkCard(padding: CGFloat = 14) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(RK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    /// A list row that draws its own card instead of the system's grouped cell.
    func rkRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self.listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
    }
    func rkScreen() -> some View {
        self.listStyle(.plain).scrollContentBackground(.hidden).background(RK.bg.ignoresSafeArea())
    }
}

struct Pill: View {
    let text: String
    var fill = RK.accentSoft
    var ink = RK.accentSoftInk
    var body: some View {
        Text(verbatim: text).font(RK.font(12, 500, style: .caption1)).monospacedDigit()
            .foregroundStyle(ink).padding(.horizontal, 9).padding(.vertical, 3)
            .background(fill, in: Capsule())
    }
}

/// One row of mutually exclusive choices, as on the web app's export panel.
struct ChoiceGroup: View {
    let title: LocalizedStringKey
    /// Each option is its shown label and its stored value.
    let options: [(String, String)]
    @Binding var selection: String
    /// Options per row; all in one row unless there are too many to read.
    var columns: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(1, columns ?? options.count)), spacing: 3) {
                ForEach(options, id: \.1) {option in
                    let (label, value) = option
                    let picked = value == selection
                    Button {selection = value} label: {
                        Text(verbatim: label).font(RK.font(14, picked ? 500 : 400)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(picked ? RK.accentInk : RK.soft)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(picked ? RK.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }.padding(3).background(RK.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

struct ToggleRow: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(RK.font(15, 500)).foregroundStyle(RK.ink)
                if let detail {Text(detail).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)}
            }
        }.tint(RK.accent)
    }
}

/// Where the rider is in the ride-to-movie path.
enum FlowStep: Int, CaseIterable {
    case video, edit, music, export, done
    var title: LocalizedStringKey {
        switch self {case .video: "סרטון"; case .edit: "עריכה"; case .music: "מוזיקה"; case .export, .done: "ייצוא"}
    }
}
struct StepBar: View {
    let current: FlowStep
    let reachable: (FlowStep) -> Bool
    let select: (FlowStep) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach([FlowStep.video, .edit, .music, .export], id: \.self) {step in
                let here = step == current || (current == .done && step == .export)
                Button {select(step)} label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(step.rawValue <= current.rawValue ? RK.accent : RK.line).frame(height: 4)
                        Text(step.title).font(RK.font(13, here ? 500 : 400, style: .footnote))
                            .foregroundStyle(here ? RK.ink : RK.faint)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!reachable(step) || here)
                .accessibilityAddTraits(here ? .isSelected : [])
            }
        }
    }
}

/// The current operation's progress, with a way out.
struct ProgressCard: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(model.message)).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.ink).lineLimit(2)
                Spacer()
                Text(verbatim: "\(Int(model.percent))%").font(RK.font(13, 400, style: .footnote)).monospacedDigit().foregroundStyle(RK.soft)
            }
            ProgressView(value: min(100, max(0, model.percent)), total: 100).tint(RK.accent)
                .accessibilityLabel("התקדמות העיבוד")
                .accessibilityValue(String(format: NSLocalizedString("%@ אחוז", comment: "Progress percent"), "\(Int(model.percent))"))
            if model.canCancel {
                Button("ביטול הפעולה") {model.cancel()}.font(RK.font(13, 500, style: .footnote)).foregroundStyle(RK.soft)
            }
        }.rkCard()
    }
}

/// The last thing the app has to say, until the rider dismisses it.
struct MessageCard: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        if !model.message.isEmpty && !model.busy {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(LocalizedStringKey(model.message)).font(RK.font(14)).foregroundStyle(RK.ink)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button {model.message = ""} label: {Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(RK.faint).frame(width: 28, height: 28)}
                        .buttonStyle(.plain).accessibilityLabel("סגירת ההודעה")
                }
                if model.photoPermissionDenied {
                    Button("פתיחת הגדרות הרשאת תמונות") {if let url = URL(string: UIApplication.openSettingsURLString) {UIApplication.shared.open(url)}}
                        .font(RK.font(14, 500)).foregroundStyle(RK.accent)
                }
                if model.saveFailed {
                    Button("ניסיון חוזר לשמירת הפרויקט") {Task {_ = await model.save()}}.font(RK.font(14, 500)).foregroundStyle(RK.accent)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RK.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
