import AppKit
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
        .commands {
            CommandGroup(after: .saveItem) {
                Button("Export Library to CSV…") {
                    exportLibraryCSV()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
                .disabled(model.movies.isEmpty)
            }
        }

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

    /// Prompts for a destination then writes a CSV snapshot of the library.
    /// Run from the File → Export menu item.
    @MainActor
    private func exportLibraryCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "movie-library.csv"
        panel.title = "Export Library to CSV"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let csv = CSVExporter.libraryCSV(movies: model.movies)
        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
