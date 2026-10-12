import SwiftUI
import UIKit
import AVFoundation

struct ProjectLibraryView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            ForEach(model.projects) {project in
                Button {
                    Task {await model.open(project); if model.project?.id == project.id {dismiss()}}
                } label: {ProjectCard(project: project)}
                .disabled(model.busy)
            }
            if model.projects.isEmpty {Text("בחרו סרטון כדי ליצור את הפרויקט הראשון שלכם.")}
        }.navigationTitle("הפרויקטים שלי")
    }
}
private struct ProjectCard: View {
    let project: LocalProject
    @State private var image: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {Image(uiImage: image).resizable().scaledToFill()}
                else {Image(systemName: "film").resizable().scaledToFit().padding(20)}
            }.frame(width: 86, height: 64).clipped().cornerRadius(8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).lineLimit(2).foregroundStyle(.primary)
                Text(project.created.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                Text(project.analyzed ? String(format: NSLocalizedString("%@ שניות · %@ סרטים שנוצרו", comment: "Project summary"), "\(Int(project.duration))", "\(project.exports.count)") : NSLocalizedString("מוכן לניתוח", comment: "Project awaiting analysis"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.task(id: project.source) {
            guard image == nil else {return}
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: LocalStore.file(project.source, project: project.id)))
            generator.maximumSize = CGSize(width: 240, height: 180); generator.appliesPreferredTrackTransform = true
            do {
                let (frame, _) = try await generator.image(at: .zero)
                try Task.checkCancellation(); image = UIImage(cgImage: frame)
            } catch {} // A missing thumbnail must not block opening a saved project.
        }
    }
}
