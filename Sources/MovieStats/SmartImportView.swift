import AppKit
import SwiftUI

/// The Smart Import window. Unlike the manual `ImportView` wizard, this runs
/// match → cleanup-planning → extras-defaults automatically against the watch
/// directory and presents just two panes:
///   1. **Review** — the Multiple-Videos decisions (extras vs delete), with
///      smart defaults pre-applied.
///   2. **Ready** — a final preview: TMDB matches, every rename before → after,
///      and every file that'll be deleted (struck through). Confirming runs
///      the whole thing.
struct SmartImportView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(SmartImportMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var model: SmartImportModel?
    /// Brief "Copied!" confirmation after the Export Plan button fires.
    @State private var planCopied = false

    private static let minWidth: CGFloat = 1000
    private static let minHeight: CGFloat = 720

    var body: some View {
        Group {
            if let model {
                content(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: Self.minWidth, minHeight: Self.minHeight)
        .onAppear {
            if model == nil {
                let created = SmartImportModel(appModel: appModel, monitor: monitor)
                model = created
                Task { await created.prepare() }
            }
        }
        .onExitCommand { dismiss() }
        .background {
            // Same Table-focus / Escape workaround as ImportView (§6.9).
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    @ViewBuilder
    private func content(model: SmartImportModel) -> some View {
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            body(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer(model: model)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(model: SmartImportModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Smart Import")
                    .font(.title2.weight(.semibold))
                if monitor.hasWatchDirectory {
                    Text(monitor.watchDirectory)
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
            HStack(spacing: 10) {
                Button("Set Watch Directory…") { pickWatchDirectory(model: model) }
                Button("Rescan") {
                    Task { await model.prepare() }
                }
                .disabled(model.phase == .preparing || model.phase == .importing)
                if model.phase == .preparing || model.phase == .importing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(model: SmartImportModel) -> some View {
        switch model.phase {
        case .preparing:
            centered {
                ProgressView("Scanning and matching the watch directory…")
            }
        case .needsWatchDir:
            emptyState(
                symbol: "eye.trianglebadge.exclamationmark",
                title: "No watch directory set",
                message: "Pick a folder to watch — Smart Import scans it for downloads it can match and import automatically.",
                model: model
            )
        case .nothingToImport:
            emptyState(
                symbol: "tray",
                title: "Nothing to import",
                message: "No videos in the watch directory confidently matched TMDB. Anything that didn't match is left untouched — use the regular Import window to match it by hand.",
                model: model
            )
        case .error:
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    Text(model.lastError ?? "Something went wrong.")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
            }
        case .review:
            reviewPane(model: model)
        case .ready:
            readyPane(model: model)
        case .importing:
            centered {
                ProgressView("Importing…")
            }
        case .done:
            donePane(model: model)
        }
    }

    // MARK: - Review pane

    @ViewBuilder
    private func reviewPane(model: SmartImportModel) -> some View {
        VStack(spacing: 0) {
            Text("Review the extra videos found alongside each matched movie. **Extra** keeps a file as bonus content under the movie's `Other/` folder; **Delete** prunes it. Samples are pre-marked for deletion; everything else defaults to Extra.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            reviewRow(file: file, model: model)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.secondary)
                            Text(group.name).fontWeight(.semibold)
                            Text("\(group.files.count) videos").foregroundStyle(.secondary)
                        }
                        .help(group.directory)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    @ViewBuilder
    private func reviewRow(file: ScannedFile, model: SmartImportModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isMain(file) {
                Text("Main movie")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else {
                Toggle("Extra", isOn: Binding(
                    get: { model.isExtra(file) },
                    set: { model.setExtra(file, $0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!model.isExtraEligible(file))
                .help(model.isExtraEligible(file)
                      ? "Keep as bonus content under the movie's Other/ folder."
                      : "No matched parent movie in this folder to attach the extra to.")
                Toggle("Delete", isOn: Binding(
                    get: { model.isMarkedForDeletion(file) },
                    set: { model.setDeletion(file, $0) }
                ))
                .toggleStyle(.checkbox)
                .help("Permanently delete this video when you import.")
            }
            Text(byteString(file.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(file.path)
    }

    // MARK: - Ready pane

    @ViewBuilder
    private func readyPane(model: SmartImportModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Final review")
                    .font(.title3.weight(.semibold))

                // TMDB matches
                section(title: "Matched to TMDB (\(model.matchedMovies.count))") {
                    ForEach(model.matchedMovies, id: \.path) { movie in
                        HStack(spacing: 8) {
                            Image(systemName: "popcorn").foregroundStyle(.secondary)
                            Text(movie.displayTitle).fontWeight(.medium)
                            if let id = movie.tmdbId {
                                Text("{tmdb-\(id)}")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                }

                // Conflicts / needs attention
                if model.hasConflicts {
                    conflictsSection(model: model)
                }

                // Renames
                let renameRows = model.rename.rows
                if !renameRows.isEmpty {
                    section(title: "Renames (\(renameRows.count))") {
                        ForEach(renameRows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if row.extraInfo != nil {
                                        Text("extra")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.pink.opacity(0.18), in: Capsule())
                                    }
                                    if !row.included {
                                        Text("skipped")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.22), in: Capsule())
                                    }
                                    Text(row.currentDisplay)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Text(row.proposedDisplay)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                if !row.subtitles.isEmpty {
                                    Text("+ \(row.subtitles.count) subtitle file(s)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption.monospaced())
                            .opacity(row.included ? 1 : 0.55)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Deletions
                let deletedVideos = model.groups
                    .flatMap(\.files)
                    .filter { model.videoDeleteSelection.contains($0.path) }
                let deletionTotal = model.imageDeletions.count + model.textDeletions.count + deletedVideos.count
                if deletionTotal > 0 {
                    section(title: "Will be permanently deleted (\(deletionTotal))") {
                        ForEach(model.imageDeletions) { deletionLine($0.path, size: $0.size) }
                        ForEach(model.textDeletions) { deletionLine($0.path, size: $0.size) }
                        ForEach(deletedVideos) { deletionLine($0.path, size: $0.size) }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Deletes are permanent — files are not moved to the Trash. Matched movies move into the library; the watch directory's empty leftover folders are pruned.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = model.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func conflictsSection(model: SmartImportModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.conflictingRows) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text("Two downloads matched the same movie — skipped to avoid a collision. Keep one (or use the Import window to tag editions/quality).")
                        .font(.caption)
                    Text(row.currentDisplay)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(model.libraryDuplicates) { dup in
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.replaceExisting
                         ? "“\(dup.imported.displayTitle)” is already in your library — the existing copy will be permanently deleted and replaced."
                         : "“\(dup.imported.displayTitle)” is already in your library — the move will be skipped (nothing is overwritten).")
                        .font(.caption)
                    ForEach(dup.existing, id: \.path) { existing in
                        Text(existing.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }

            if !model.libraryDuplicates.isEmpty {
                Toggle(isOn: Binding(
                    get: { model.replaceExisting },
                    set: { model.replaceExisting = $0 }
                )) {
                    Text("Replace existing library copies (permanently deletes the old copy — no Trash)")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func deletionLine(_ path: String, size: Int64) -> some View {
        HStack(spacing: 6) {
            Text(path)
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(byteString(size))
                .foregroundStyle(.tertiary)
        }
        .font(.caption.monospaced())
    }

    // MARK: - Done pane

    @ViewBuilder
    private func donePane(model: SmartImportModel) -> some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: model.lastError == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(model.lastError == nil ? .green : .orange)
                Text(model.lastError == nil ? "Import complete" : "Import finished with issues")
                    .font(.title3)
                if let error = model.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                } else {
                    Text("The matched movies were moved into your library and the database updated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                HStack {
                    Button("Scan Again") { Task { await model.prepare() } }
                    Button("Close") { dismiss() }
                }
                .controlSize(.large)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(model: SmartImportModel) -> some View {
        HStack(spacing: 12) {
            Spacer()
            switch model.phase {
            case .review:
                Button {
                    Task { await model.proceedToReady() }
                } label: {
                    HStack { Text("Continue"); Image(systemName: "chevron.right") }
                }
                .keyboardShortcut(.defaultAction)
            case .ready:
                if !model.groups.isEmpty {
                    Button {
                        model.backToReview()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
                Button {
                    Task {
                        let text = await model.exportPlanText()
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                        planCopied = true
                        try? await Task.sleep(for: .seconds(2))
                        planCopied = false
                    }
                } label: {
                    Label(planCopied ? "Copied!" : "Export Plan",
                          systemImage: planCopied ? "checkmark" : "doc.on.clipboard")
                }
                .help("Copy a full text report of the plan + watch-directory inventory to the clipboard, to paste into an LLM.")
                Button {
                    Task { await model.execute() }
                } label: {
                    Label("Import to Library", systemImage: "tray.and.arrow.up")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appModel.hasDirectory)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Inner: View>(title: String, @ViewBuilder _ inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            inner()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func emptyState(symbol: String, title: String, message: String, model: SmartImportModel) -> some View {
        centered {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(title).font(.title3)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Button("Set Watch Directory…") { pickWatchDirectory(model: model) }
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func centered<Inner: View>(@ViewBuilder _ inner: () -> Inner) -> some View {
        VStack {
            Spacer()
            inner()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func pickWatchDirectory(model: SmartImportModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Watch Directory"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            monitor.setWatchDirectory(url.path)
            Task { await model.prepare() }
        }
    }
}
