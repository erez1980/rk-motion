import SwiftUI
import UIKit

/// "Tell me what to change": an edit or a search in the rider's own words.
struct AskCard: View {
    @ObservedObject var model: EditorModel
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
                    .background(RK.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    }
    private func send() {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !asking else {return}
        asking = true; focused = false
        Task {
            await model.chat(request)
            text = ""; asking = false
        }
    }
}

/// The people seen in the footage; the one tapped becomes the movie's star.
struct StarCard: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("כוכב הסרט", systemImage: "star.circle").font(RK.font(15, 600)).foregroundStyle(RK.ink)
            Text("בחרו אדם, והסרט יתמקד ברגעים שהוא בפריים.").font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.people) {person in
                        let picked = model.star == person.key
                        Button {model.setStar(picked ? nil : person.key)} label: {
                            VStack(spacing: 4) {
                                FacePicture(model: model, person: person)
                                    .frame(width: 60, height: 60).clipShape(Circle())
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
                        .accessibilityLabel(picked ? Text("הכוכב שנבחר") : Text("בחירה ככוכב"))
                        .accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }.padding(.vertical, 2)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .rkCard()
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

/// A movie made from the library by itself: the latest trip, the month or the year.
struct RecapSheet: View {
    let make: (Recap.Span) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("אבחר בעצמי סרטונים ותמונות מהגלריה, מפוזרים לאורך הזמן ומועדפים קודם, ואערוך מהם סרט של דקה.")
                    .font(RK.font(14)).foregroundStyle(RK.soft).fixedSize(horizontal: false, vertical: true)
                ForEach(Recap.Span.allCases) {span in
                    Button {dismiss(); make(span)} label: {
                        HStack(spacing: 12) {
                            Image(systemName: span.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(RK.accent)
                                .frame(width: 44, height: 44).background(RK.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: span.title).font(RK.font(16, 600)).foregroundStyle(RK.ink)
                                Text(verbatim: span.detail).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).foregroundStyle(RK.faint)
                        }
                        .padding(10).background(RK.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("recap." + span.rawValue)
                }
                Spacer()
            }
            .padding(20)
            .background(RK.bg.ignoresSafeArea())
            .navigationTitle("סיכום מהגלריה").navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement: .cancellationAction) {Button("ביטול") {dismiss()}}}
        }
        .tint(RK.accent)
        .environment(\.layoutDirection, AppLanguage.direction)
    }
}
