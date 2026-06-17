import AppKit
import SwiftUI

@main
struct MovieStatsApp: App {
    @State private var model = AppModel()
    @State private var chatModel = ChatModel()
    @State private var smartImport = SmartImportMonitor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // A single main window — the model is app-wide state, so a second
        // main window would just mirror the first.
        Window("Movie Stats", id: "main") {
            ContentView()
                .environment(model)
                .environment(chatModel)
                .environment(smartImport)
                .task { smartImport.start() }
                .onChange(of: scenePhase) { _, phase in
                    // Re-scan the watch dir whenever the app comes to the
                    // foreground so the blue button reflects files added while
                    // the app was in the background — the hourly poll alone is
                    // too coarse to notice a fresh download promptly.
                    if phase == .active {
                        Task { await smartImport.scanNow() }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
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
            LibraryCommands(model: model)
            // No help book ships with the app — an inert "MovieStats Help"
            // item would violate the HIG, so remove the default.
            CommandGroup(replacing: .help) {}
        }

        Settings {
            SettingsView()
                .environment(smartImport)
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

        Window("Match Library to TMDB", id: "tmdb-matcher") {
            MatcherView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Rename Library", id: "rename-library") {
            RenameView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Import", id: "import") {
            ImportView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Smart Import", id: "smart-import") {
            SmartImportView()
                .environment(model)
                .environment(smartImport)
        }
        .windowResizability(.contentMinSize)

        Window("IMDb Ratings", id: "imdb-ratings") {
            IMDbView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Library Reports", id: "reports") {
            ReportsView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Collections", id: "collections") {
            CollectionsView()
                .environment(model)
        }
        .windowResizability(.contentMinSize)

        Window("Insights", id: "insights") {
            InsightsView()
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

/// The Library menu — every workflow reachable from the toolbar is also
/// reachable (and keyboard-drivable) from the menu bar, per macOS convention.
private struct LibraryCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Library") {
            Button("Open Directory…") { model.chooseDirectory() }
                .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(model.recentDirectories, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) {
                        model.setDirectory(path)
                    }
                }
                Divider()
                Button("Clear Menu") { model.clearRecentDirectories() }
                    .disabled(model.recentDirectories.isEmpty)
            }

            Divider()

            Button("Rescan") { Task { await model.rescan() } }
                .keyboardShortcut("r")
                .disabled(!model.hasDirectory || model.isScanning)

            Button("Reprobe All") { Task { await model.reprobeAll() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.hasDirectory || model.isScanning || model.isProbing)

            Divider()

            Button("Import…") { openWindow(id: "import") }
                .keyboardShortcut("i")

            Button("Smart Import…") { openWindow(id: "smart-import") }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Match Library to TMDB…") { openWindow(id: "tmdb-matcher") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.hasDirectory)

            Button("Rename Library…") { openWindow(id: "rename-library") }
                .disabled(!model.hasDirectory)

            Divider()

            Menu("Cleanup") {
                Button("Images…") { openWindow(id: CleanupCategory.images.id) }
                Button("Text Files…") { openWindow(id: CleanupCategory.text.id) }
                Button("Multiple Videos per Folder…") { openWindow(id: "duplicates") }
                Button("Empty Folders…") { openWindow(id: "empty-folders") }
            }
            .disabled(!model.hasDirectory)

            Button("IMDb Ratings…") { openWindow(id: "imdb-ratings") }

            Divider()

            // ⌥⌘ rather than ⇧⌘ — ⇧⌘3/4/5 are the system screenshot
            // shortcuts and would swallow these before the app sees them.
            // No ellipsis: these windows show information, they don't ask
            // for further input.
            Button("Library Reports") { openWindow(id: "reports") }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(!model.hasDirectory)

            Button("Collections") { openWindow(id: "collections") }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(!model.hasDirectory)

            Button("Insights") { openWindow(id: "insights") }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(!model.hasDirectory)
        }
    }
}
