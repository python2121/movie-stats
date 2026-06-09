import AppKit
import SwiftUI

/// The import wizard window. Walks the user through:
///   1. Pick a source directory (e.g. `/complete/SomeMovie`)
///   2. TMDB matching against just the scanned source
///   3. Image / text-file / multi-video / empty-folder cleanup,
///      scoped to the source
///   4. Renaming into canonical Plex / Jellyfin form
///   5. Move to Library — physically moves into the live library
///      directory and registers the new entries in the main DB
///
/// The wizard owns an `ImportSession` which conforms to `MovieScope`
/// so the existing matcher / rename views can drive their UI against
/// the source without touching the persistent library state until the
/// user clicks Move to Library.
struct ImportView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var session: ImportSession?

    /// Outer frame defaults for the wizard window. The matcher and
    /// rename inner panels happily fill more space, so we go large.
    private static let minWidth: CGFloat = 1000
    private static let minHeight: CGFloat = 720

    var body: some View {
        Group {
            if let session {
                content(session: session)
                    .environment(session)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        .onAppear {
            if session == nil { session = ImportSession(appModel: appModel) }
        }
        .onExitCommand { dismiss() }
    }

    @ViewBuilder
    private func content(session: ImportSession) -> some View {
        VStack(spacing: 0) {
            header(session: session)
            Divider()
            body(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(session: session)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(session: ImportSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Import")
                    .font(.title2.weight(.semibold))
                if !session.sourceDirectory.isEmpty {
                    Text(session.sourceDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if appModel.hasDirectory {
                    Text("→ \(appModel.directoryPath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Library destination")
                }
            }
            stepIndicator(session: session)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Horizontal pill row showing every step with the active one
    /// highlighted. Past steps are tappable so the user can jump back.
    @ViewBuilder
    private func stepIndicator(session: ImportSession) -> some View {
        // The Done step is terminal — hide it from the indicator.
        let visible = ImportSession.Step.allCases.filter { $0 != .done }
        HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.element) { index, step in
                let active = session.currentStep == step
                let reachable = step.rawValue <= session.currentStep.rawValue
                Button {
                    if reachable { session.jump(to: step) }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(active ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.2))
                            )
                        Text(step.title)
                            .font(.caption)
                            .foregroundStyle(active ? .primary : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(active ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!reachable)
                if index < visible.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Body — per-step content

    @ViewBuilder
    private func body(session: ImportSession) -> some View {
        switch session.currentStep {
        case .pickDirectory:
            pickPanel(session: session)
        case .match:
            embeddedSection(title: "Match each scanned file to TMDB. Confirmed matches drop off the list.") {
                MatcherView(scopedScope: session, embedded: true)
            }
        case .images:
            embeddedSection(title: "Delete image files (posters, screenshots, etc.) you don't want to keep with the movie.") {
                FileCleanupView(category: .images, scopedDirectory: session.sourceDirectory, embedded: true)
            }
        case .text:
            embeddedSection(title: "Delete NFO / txt / rtf files left over from the release.") {
                FileCleanupView(category: .text, scopedDirectory: session.sourceDirectory, embedded: true)
            }
        case .multiVideo:
            embeddedSection(title: "Folders with multiple video files (samples, extras). Keep one; delete the rest.") {
                DuplicatesView(scopedDirectory: session.sourceDirectory, embedded: true)
            }
        case .emptyFolders:
            embeddedSection(title: "Folders left empty after the previous cleanups. Safe to delete.") {
                EmptyFoldersView(scopedDirectory: session.sourceDirectory, embedded: true)
            }
        case .rename:
            embeddedSection(title: "Rename every matched file into canonical Plex / Jellyfin form before moving.") {
                RenameView(scopedScope: session, embedded: true)
            }
        case .ready:
            readyPanel(session: session)
        case .done:
            donePanel()
        }
    }

    /// Common scaffolding for every step that wraps one of the existing
    /// cleanup / matcher / rename views: a short headline at the top
    /// and the embedded view filling the rest of the body.
    @ViewBuilder
    private func embeddedSection<Inner: View>(
        title: String,
        @ViewBuilder _ inner: () -> Inner
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            inner()
        }
    }

    // MARK: - Step 0 (pick) panel

    @ViewBuilder
    private func pickPanel(session: ImportSession) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Pick a source directory to import")
                .font(.title3)
            Text("e.g. /complete/<a downloaded movie folder>")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose Directory…") { pickDirectory(session: session) }
                .controlSize(.large)
                .disabled(session.isBusy)
            if session.isBusy {
                ProgressView(session.busyMessage)
                    .frame(maxWidth: 280)
            }
            if let error = session.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 480)
                    .multilineTextAlignment(.center)
            }
            if !session.sourceDirectory.isEmpty {
                Text("\(session.movies.count) video file(s) found in \(session.sourceDirectory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Step 7 (ready) panel — Move to Library

    @ViewBuilder
    private func readyPanel(session: ImportSession) -> some View {
        let matched = session.movies.filter { $0.tmdbId != nil }.count
        let total = session.movies.count
        let canMove = total > 0 && appModel.hasDirectory && !session.isBusy

        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to move into the library")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                summaryRow(symbol: "tray.full", label: "Source", value: session.sourceDirectory)
                summaryRow(symbol: "house", label: "Library", value: appModel.directoryPath)
                summaryRow(symbol: "film", label: "Files",
                           value: "\(total) video file(s)  ·  \(matched) matched to TMDB")
            }

            Text("Move to Library will rename every top-level item from the source into the library directory, then rescan the library and apply the TMDB matches you confirmed. Nothing in the library is overwritten — items already present at the destination are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = session.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            HStack {
                Spacer()
                if session.isBusy {
                    ProgressView(session.busyMessage)
                        .frame(width: 240)
                }
                Button {
                    Task { await session.moveToLibrary() }
                } label: {
                    Label("Move to Library", systemImage: "tray.and.arrow.up")
                        .font(.body.weight(.semibold))
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canMove)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func summaryRow(symbol: String, label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.body.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Step 8 (done) panel

    @ViewBuilder
    private func donePanel() -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Import complete")
                .font(.title3)
            Text("The files were moved into your library and the database has been updated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Close") { dismiss() }
                .controlSize(.large)
            Button("Import Another") {
                // Reset back to the picker — the AppModel is still
                // live so the same wizard window can be reused for a
                // second batch.
                if let session = session {
                    session.jump(to: .pickDirectory)
                }
            }
            .buttonStyle(.borderless)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(session: ImportSession) -> some View {
        HStack(spacing: 12) {
            Button("Cancel Import") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if session.currentStep != .pickDirectory, session.currentStep != .done {
                Button {
                    session.retreat()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(session.currentStep.previous == nil || session.isBusy)
            }
            if session.currentStep != .pickDirectory, session.currentStep != .ready, session.currentStep != .done {
                Button {
                    session.advance()
                } label: {
                    HStack {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.currentStep.next == nil || session.isBusy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    /// Spawns an NSOpenPanel for choosing the source directory. On
    /// pick, hands the path to the session which kicks off a scan and
    /// advances to the match step automatically when files were found.
    private func pickDirectory(session: ImportSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Source Directory"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            Task { await session.setSourceDirectory(path) }
        }
    }
}
