import AppKit
import SwiftUI

/// The standard macOS Settings window (⌘,). Holds the TMDB API key — which
/// used to live behind a File-menu NSAlert — plus pointers to the app's
/// on-disk data.
struct SettingsView: View {
    @Environment(SmartImportMonitor.self) private var smartImport
    @State private var apiKey = TMDBService.apiKey ?? ""

    private var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MovieStats", isDirectory: true)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, newValue in
                        TMDBService.setAPIKey(newValue)
                    }
                LabeledContent("Status") {
                    if TMDBService.apiKey != nil {
                        Label("Key saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("No key — TMDB matching is disabled", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Link("Get a key at themoviedb.org → Settings → API",
                     destination: URL(string: "https://www.themoviedb.org/settings/api")!)
            } header: {
                Text("TMDB")
            } footer: {
                Text("Accepts either a v3 API key or a v4 read-access token.")
            }

            Section {
                LabeledContent("Watch directory") {
                    Text(smartImport.hasWatchDirectory ? smartImport.watchDirectory : "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Choose…") { chooseWatchDirectory() }
            } header: {
                Text("Smart Import")
            } footer: {
                Text("The folder Smart Import watches for downloads. It's scanned about once an hour while the app is open; the toolbar button turns blue when something confidently matches TMDB.")
            }

            Section("Data") {
                LabeledContent("Database & posters") {
                    Text(supportDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([supportDirectory])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseWatchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Watch Directory"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            smartImport.setWatchDirectory(url.path)
        }
    }
}
