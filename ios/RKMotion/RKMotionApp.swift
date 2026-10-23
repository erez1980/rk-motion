import SwiftUI
import UIKit

@main struct RKMotionApp: App {
    init() {
        // The navigation bar is UIKit's; give it the same colours and type.
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = RK.UI.bg
        bar.shadowColor = .clear
        bar.titleTextAttributes = [.font: RK.uiFont(17, 700, style: .headline), .foregroundColor: RK.UI.ink]
        bar.largeTitleTextAttributes = [.font: RK.uiFont(30, 700, style: .largeTitle), .foregroundColor: RK.UI.ink]
        let item = UIBarButtonItemAppearance()
        item.normal.titleTextAttributes = [.font: RK.uiFont(16), .foregroundColor: RK.UI.soft]
        bar.buttonAppearance = item; bar.backButtonAppearance = item
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
        UINavigationBar.appearance().tintColor = RK.UI.soft
    }
    var body: some Scene {WindowGroup {RootView().environment(\.layoutDirection, AppLanguage.direction)}}
}

struct RootView: View {
    private enum Route: Hashable {case project, about}
    @StateObject private var model = EditorModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    var body: some View {
        NavigationStack(path: $path) {
            HomeView(model: model, newRide: {
                Task {await model.close(); if model.project == nil {path = [.project]}}
            }, open: {project in
                Task {await model.open(project); if model.project?.id == project.id {path = [.project]}}
            }, about: {path = [.about]}, recap: {span in
                Task {await model.close(); if model.project == nil {path = [.project]; model.makeRecap(span)}}
            }, automatic: {
                Task {await model.close(); if model.project == nil {path = [.project]; model.makeRecap(.month, automatic: true)}}
            })
            .navigationDestination(for: Route.self) {route in
                switch route {
                case .project: ProjectFlowView(model: model)
                case .about: AboutView(clean: {await model.cleanTemporaryFiles()})
                }
            }
        }
        .tint(RK.accent)
        .task {
            await model.restore()
            #if DEBUG
            // Earlier test rides go before the project screen opens: deleting
            // the open one would close the screen again.
            if UITestFixture.requested {await model.discardTestRides(); path = [.project]; await UITestFixture.load(into: model)}
            #endif
        }
        .onChange(of: model.edit) {previous, _ in model.changed(from: previous)}
        .onChange(of: scenePhase) {_, phase in
            if phase == .background {model.pause()}
            else if phase == .active {model.foreground()}
        }
    }
}
