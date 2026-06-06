import AppKit
import SwiftUI

@main
struct MovieStatsApp: App {
    @State private var model = AppModel()
    @State private var chatModel = ChatModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(chatModel)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Anchored to .newItem so the entry appears near the top of the
            // File menu, above Close.
            CommandGroup(after: .newItem) {
                Button("Export Library to CSV…") {
                    exportLibraryCSV()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
                .disabled(model.movies.isEmpty)
            }
            CommandGroup(after: .appSettings) {
                Button("TMDB API Key…") {
                    promptForTMDBKey()
                }
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

    /// Opens an NSAlert with an inline text field for the user's TMDB API
    /// key (either a v3 key or a v4 read access token). Persists via
    /// `TMDBService.setAPIKey`.
    @MainActor
    private func promptForTMDBKey() {
        let alert = NSAlert()
        alert.messageText = "TMDB API Key"
        alert.informativeText = "Paste your TMDB API key (v3) or read-access token (v4). Get one at themoviedb.org → Settings → API."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "API key"
        field.stringValue = TMDBService.apiKey ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            TMDBService.setAPIKey(field.stringValue)
        }
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
