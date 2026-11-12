import SwiftUI
import UIKit

/// "Tell me what to change": an edit or a search in the rider's own words.
struct AskCard: View {
    @ObservedObject var model: EditorModel
    /// Called once a request was handled, to close the sheet it sits in.
    var done: (() -> Void)?
    @State private var text = ""
    @State private var asking = false
    @FocusState private var focused: Bool
    static let examples = ["חצי דקה", "יותר הילוך איטי", "בלי ווש", "קטעים של 3 שניות", "תמצא את הים"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("מה לשנות?", systemImage: "text.bubble").font(RK.font(15, 600)).foregroundStyle(RK.ink)
            HStack(spacing: 8) {
                TextField("למשל: תקצר לחצי דקה ותוסיף זום על הביט", text: $text, axis: .vertical)
                    .font(RK.font(15)).lineLimit(1...3).focused($focused).submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RK.raised, in: RoundedRectangle(cornerRadius: RK.Radius.small, style: .continuous))
                    .accessibilityIdentifier("ask.field")
                Button(action: send) {
                    Group {
                        if asking {ProgressView().tint(RK.accentInk)}
                        else {Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold))}
                    }
                    .foregroundStyle(RK.accentInk).frame(width: 40, height: 40).background(RK.accent, in: Circle())
                }
                .buttonStyle(.plain).disabled(asking || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("שליחה").accessibilityIdentifier("ask.send")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.examples, id: \.self) {example in
                        Button {text = example; send()} label: {
                            Text(LocalizedStringKey(example)).font(RK.font(12, 500, style: .caption1)).foregroundStyle(RK.accentSoftInk)
                                .padding(.horizontal, 10).frame(minHeight: 30).background(RK.accentSoft, in: Capsule())
                        }.buttonStyle(.plain).disabled(asking)
                    }
                }
            }
            if !model.canSearch {
                Text("החיפוש בתוך הסרטונים זמין אחרי ניתוח מחדש.").font(RK.font(12, 400, style: .caption1)).foregroundStyle(RK.soft)
            }
        }
        .rkCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.card")
        .onAppear {focused = true}
    }
    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !asking else {return}
        asking = true; focused = false
        Task {
            await model.chat(request)
            text = ""; asking = false
            done?()
        }
    }
}

/// The people seen in the footage; the one tapped becomes the movie's star.
struct StarCard: View {
    @ObservedObject var model: EditorModel
    /// Inside the detection card: a smaller row, without a card of its own.
    var embedded = false
    var body: some View {
        if embedded {content.padding(.top, 4)} else {content.rkCard()}
    }
    private var side: CGFloat {embedded ? 48 : 60}
    private var content: some View {
        VStack(alignment: .leading, spacing: embedded ? 8 : 10) {
            Label("כוכב הסרט", systemImage: "star.circle").font(RK.font(embedded ? 14 : 15, 600)).foregroundStyle(RK.ink)
            Text("בחרו אדם, והסרט יתמקד ברגעים שהוא בפריים.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(model.people.enumerated()), id: \.element.id) {index, person in
                        let picked = model.star == person.key
                        Button {model.setStar(picked ? nil : person.key)} label: {
                            VStack(spacing: 4) {
                                FacePicture(model: model, person: person)
                                    .frame(width: side, height: side).clipShape(Circle())
                                    .overlay(Circle().stroke(picked ? RK.accent : RK.line, lineWidth: picked ? 3 : 1))
                                    .overlay(alignment: .bottomTrailing) {
                                        if picked {
                                            Image(systemName: "star.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(RK.accentInk)
                                                .frame(width: 20, height: 20).background(RK.accent, in: Circle())
                                        }
                                    }
                                Text(verbatim: String(format: NSLocalizedString("%@ פעמים", comment: "How often a person is seen in the footage"), "\(person.members.count)"))
                                    .font(RK.font(11, 400, style: .caption2)).monospacedDigit().foregroundStyle(RK.soft)
                            }
                        }
                        .buttonStyle(.plain)
                        // Each face is told apart: its number and how often it is seen.
                        .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("אדם %1$@, נראה %2$@ פעמים", comment: "A person to pick as the movie's star, for VoiceOver"), "\(index + 1)", "\(person.members.count)")))
                        .accessibilityHint(picked ? Text("הכוכב שנבחר") : Text("בחירה ככוכב"))
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }.padding(.vertical, 2)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("star.card")
    }
}

private struct FacePicture: View {
    @ObservedObject var model: EditorModel
    let person: FaceGroups.Group
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image {Image(uiImage: image).resizable().scaledToFill()}
            else {Image(systemName: "person.fill").font(.system(size: 24)).foregroundStyle(RK.faint).frame(maxWidth: .infinity, maxHeight: .infinity).background(RK.raised)}
        }
        .task(id: person.key) {
            guard let spot = model.picture(of: person) else {return}
            image = await FaceGroups.picture(spot.file, at: spot.seconds, face: spot.face)
        }
    }
}
