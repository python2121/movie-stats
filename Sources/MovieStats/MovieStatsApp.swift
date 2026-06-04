import SwiftUI

@main
struct MovieStatsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window(CleanupCategory.images.title, id: CleanupCategory.images.id) {
            FileCleanupView(category: .images)
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window(CleanupCategory.text.title, id: CleanupCategory.text.id) {
            FileCleanupView(category: .text)
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Multiple Videos per Folder", id: "duplicates") {
            DuplicatesView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Empty Folders", id: "empty-folders") {
            EmptyFoldersView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)
    }
}
