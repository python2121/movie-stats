import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            HStack(spacing: 16) {
                StatCard(title: "Movies", value: "\(model.movieCount)", systemImage: "film")
                StatCard(title: "Larger than 20 GB", value: "\(model.largeMovieCount)", systemImage: "externaldrive.badge.exclamationmark")
                StatCard(title: "Total Size", value: byteString(model.totalSize), systemImage: "internaldrive")
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            movieList
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 380)
        .toolbar { toolbarContent }
        .overlay {
            if model.isScanning {
                ProgressView("Scanning…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Movie Stats")
                .font(.largeTitle.bold())
            if model.hasDirectory {
                Text(model.directoryPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.directoryPath)
            } else {
                Text("Open a directory to begin scanning for movies.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Ranked list of every movie, largest first, with its size.
    private var movieList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.movies.isEmpty {
                Spacer()
                Text(model.hasDirectory ? "No movies found." : "No movies scanned yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                Text("Movies by size")
                    .font(.headline)
                List {
                    ForEach(Array(model.moviesBySize.enumerated()), id: \.element.id) { index, movie in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.filename)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(movie.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(byteString(movie.size))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .help(movie.path)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                openDirectory()
            } label: {
                Label("Open Directory", systemImage: "folder")
            }
            .help("Choose a directory to scan")

            Button {
                Task { await model.rescan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(!model.hasDirectory || model.isScanning)
            .help("Rescan the current directory")

            Spacer()

            Button {
                openWindow(id: CleanupCategory.images.id)
            } label: {
                Label("Scan Images", systemImage: "photo.on.rectangle")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for images")

            Button {
                openWindow(id: CleanupCategory.text.id)
            } label: {
                Label("Scan Text Files", systemImage: "doc.text")
            }
            .disabled(!model.hasDirectory)
            .help("Scan this directory for .txt and .nfo files")
        }
    }

    // MARK: - Actions

    private func openDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a directory to scan for movies"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.directoryPath = url.path
        Task { await model.rescan() }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A simple stat tile for the main window.
private struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
