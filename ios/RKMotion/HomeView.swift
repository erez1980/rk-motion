import SwiftUI
import UIKit

/// The first screen: start a new ride or return to one.
struct HomeView: View {
    @ObservedObject var model: EditorModel
    let newRide: () -> Void
    let open: (LocalProject) -> Void
    let about: () -> Void
    var body: some View {
        ScrollView {
            // Lazy, so a long list asks only for the pictures on screen.
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text(verbatim: "RK ").foregroundStyle(RK.ink) + Text(verbatim: "Motion").foregroundStyle(RK.accent))
                            .font(RK.font(28, 700, style: .largeTitle))
                        Text("מכל סרטון לרגעים הטובים").font(RK.font(15)).foregroundStyle(RK.soft)
                    }
                    Spacer()
                    Button(action: about) {
                        Image(systemName: "questionmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(RK.soft)
                            .frame(width: 44, height: 44).background(RK.card, in: Circle())
                    }.accessibilityLabel("עזרה")
                }.padding(.top, 8)
                if model.busy {
                    ProgressCard(model: model)
                    if model.project != nil {
                        Button("חזרה לפרויקט הפעיל") {if let p = model.project {open(p)}}.buttonStyle(SecondaryButtonStyle())
                    }
                }
                Button(action: newRide) {
                    HStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                            .frame(width: 52, height: 52).background(RK.accentInk.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("סרטון חדש").font(RK.font(19, 700, style: .title3))
                            Text("בחירת סרטון מהתמונות או מהקבצים").font(RK.font(14)).opacity(0.75)
                        }
                        Spacer()
                    }
                    .foregroundStyle(RK.accentInk).padding(16)
                    .background(RK.accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }.buttonStyle(.plain).accessibilityIdentifier("home.newRide").disabled(model.busy).opacity(model.busy ? 0.4 : 1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("הפרויקטים שלי").font(RK.font(17, 500, style: .headline)).foregroundStyle(RK.ink)
                    Text(verbatim: "\(model.projects.count)").font(RK.font(13)).foregroundStyle(RK.soft)
                }.padding(.top, 4)
                if model.projects.isEmpty {
                    Text("בחרו סרטון כדי ליצור את הפרויקט הראשון שלכם.").font(RK.font(15)).foregroundStyle(RK.soft).rkCard(padding: 16)
                }
                ForEach(model.projects) {project in
                    Button {open(project)} label: {ProjectRow(project: project)}
                        .buttonStyle(.plain).disabled(model.busy)
                }
                MessageCard(model: model)
                Text(AppVersion.line).font(RK.font(12, 400, style: .caption2)).monospacedDigit().foregroundStyle(RK.faint)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(RK.bg.ignoresSafeArea())
        .navigationTitle("הפרויקטים")
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct ProjectRow: View {
    let project: LocalProject
    @State private var image: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image {Image(uiImage: image).resizable().scaledToFill()}
                    else {Image(systemName: "film").font(.system(size: 22)).foregroundStyle(RK.faint).frame(maxWidth: .infinity, maxHeight: .infinity).background(RK.raised)}
                }.frame(width: 86, height: 64).clipped()
                if project.duration > 0 {
                    Text(verbatim: RK.clock(project.duration)).font(RK.font(11, 500, style: .caption2)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5)).padding(5)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: project.name).font(RK.font(16, 500)).foregroundStyle(RK.ink).lineLimit(1)
                Text(verbatim: meta).font(RK.font(13, 400, style: .footnote)).foregroundStyle(RK.soft).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward").font(.system(size: 14, weight: .semibold)).foregroundStyle(RK.faint)
        }
        .padding(10).background(RK.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .task(id: project.source) {
            guard image == nil else {return}
            // A missing thumbnail must not block opening a saved project.
            image = await Thumbnails.shared.image(for: project)
        }
    }
    private var meta: String {
        let date = project.created.formatted(date: .abbreviated, time: .omitted)
        guard project.analyzed else {return date}
        let clips = project.edit.clips.filter {$0.selected != false}.count
        return date + " · " + clipCount(clips)
    }
    @ViewBuilder private var status: some View {
        if !project.analyzed {Pill(text: NSLocalizedString("ממתין לניתוח", comment: "Project awaiting analysis"))}
        else if project.exports.isEmpty {Pill(text: NSLocalizedString("בעריכה", comment: "Project being edited"), fill: RK.raised, ink: RK.soft)}
        else {Pill(text: project.exports.count == 1 ? NSLocalizedString("סרט אחד", comment: "One movie made from a project") : String(format: NSLocalizedString("%@ סרטים", comment: "Movies made from a project"), "\(project.exports.count)"), fill: RK.good.opacity(0.14), ink: RK.good)}
    }
}
