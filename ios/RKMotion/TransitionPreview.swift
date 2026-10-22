import SwiftUI
import UIKit

/// A small looping picture of a transition: one shot holds, passes into the
/// next the way the movie will, and the next holds. Drawn with the movie's
/// own frames when there are some, so the rider sees it before choosing.
struct TransitionPreview: View {
    let style: String
    var first: UIImage?
    var second: UIImage?
    /// One loop: hold, transition, hold.
    static let loop = 2.4, hold = 0.8
    /// The styles "smart" cycles through, one each loop.
    static let smartCycle = ["zoom", "dissolve", "slide", "flash", "fade"]
    var body: some View {
        TimelineView(.animation) {context in
            let time = context.date.timeIntervalSinceReferenceDate
            let round = Int(time / Self.loop)
            let shown = style == SmartTransitions.name ? Self.smartCycle[round % Self.smartCycle.count] : style
            let t = Self.progress(at: time.truncatingRemainder(dividingBy: Self.loop))
            GeometryReader {geometry in
                picture(shown, t: t, width: geometry.size.width)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .clipped()
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityHidden(true)
    }
    /// How far through the transition the loop is at `moment` seconds into it, 0 … 1.
    static func progress(at moment: Double) -> Double {
        let span = loop - hold * 2
        return min(1, max(0, (moment - hold) / span))
    }
    @ViewBuilder private func picture(_ style: String, t: Double, width: CGFloat) -> some View {
        let a = shot(first, tint: Color(red: 0.95, green: 0.55, blue: 0.2), letter: "A")
        let b = shot(second, tint: Color(red: 0.25, green: 0.5, blue: 0.95), letter: "B")
        switch style {
        case "dissolve":
            ZStack {b; a.opacity(1 - t)}
        case "fade", "flash":
            ZStack {
                (style == "flash" ? Color.white : Color.black)
                if t < 0.5 {a.opacity(1 - t * 2)} else {b.opacity(t * 2 - 1)}
            }
        case "slide":
            ZStack {
                a.offset(x: -CGFloat(t) * width)
                b.offset(x: CGFloat(1 - t) * width)
            }
        case "zoom":
            ZStack {b; a.scaleEffect(1 + 0.35 * t).opacity(1 - t)}
        default:
            if t < 0.5 {a} else {b}
        }
    }
    private func shot(_ image: UIImage?, tint: Color, letter: String) -> some View {
        ZStack {
            if let image {Image(uiImage: image).resizable().scaledToFill()}
            else {
                LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(verbatim: letter).font(RK.font(16, 700)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}

/// The transitions as tiles that each play their own preview.
struct TransitionPicker: View {
    let options: [String]
    @Binding var selection: String
    var first: UIImage?
    var second: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("מעבר בין קטעים").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(options, id: \.self) {option in
                    let picked = option == selection
                    Button {selection = option} label: {
                        VStack(spacing: 4) {
                            TransitionPreview(style: option, first: first, second: second)
                                .frame(height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(verbatim: StyleSheetNames.transition(option)).font(RK.font(13, picked ? 600 : 400))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(picked ? RK.ink : RK.soft)
                        }
                        .padding(5)
                        .background(picked ? RK.accentSoft : RK.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(picked ? RK.accent : Color.clear, lineWidth: 2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: StyleSheetNames.transition(option)))
                    .accessibilityAddTraits(picked ? .isSelected : [])
                    .accessibilityIdentifier("transition." + option)
                }
            }
        }
    }
}

/// What each transition is called on screen.
enum StyleSheetNames {
    static func transition(_ value: String) -> String {
        switch value {
        case SmartTransitions.name: return NSLocalizedString("חכם ✨", comment: "Smart transitions, chosen per seam")
        case "dissolve": return NSLocalizedString("המסה", comment: "Dissolve transition")
        case "fade": return NSLocalizedString("דעיכה", comment: "Dip-to-black transition")
        case "flash": return NSLocalizedString("הבזק", comment: "Flash-to-white transition")
        case "slide": return NSLocalizedString("החלקה", comment: "Push transition")
        case "zoom": return NSLocalizedString("זום", comment: "Zoom transition")
        default: return NSLocalizedString("חיתוך", comment: "Cut transition")
        }
    }
}
