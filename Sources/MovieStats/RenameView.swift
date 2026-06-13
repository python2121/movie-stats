import AppKit
import SwiftUI

/// "Rename Library" window. Three-column table with current path, proposed
/// path, and include checkbox. Special-character rows float to the top.
/// Apply runs serially with a live "currently renaming" status.
struct RenameView: View {
    /// Optional scope override. When set, the rename model is built
    /// against this scope (e.g. an `ImportSession`) instead of the
    /// live `appModel`. Set by the import wizard.
    let scopedScope: (any MovieScope)?
    /// Drops window-style chrome when embedded inside another
    /// container.
    let embedded: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var renamer: RenameModel?
    @State private var confirmingApply = false

    init(scopedScope: (any MovieScope)? = nil, embedded: Bool = false) {
        self.scopedScope = scopedScope
        self.embedded = embedded
    }

    /// Width of the right-hand checkbox column. Same value used by the
    /// header cell and each row to keep things aligned.
    private static let includeColumnWidth: CGFloat = 80

    var body: some View {
        Group {
            if let renamer {
                if renamer.isLoading {
                    loadingView(model: renamer)
                } else {
                    content(model: renamer)
                        .environment(renamer)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: embedded ? nil : 880, minHeight: embedded ? nil : 540)
        .onAppear {
            if renamer == nil {
                renamer = RenameModel(scope: scopedScope ?? appModel)
            }
            guard let r = renamer, !r.isApplying, !r.isLoading else { return }
            // Dispatch reload as a Task so the per-row directory
            // enumeration can yield to the main actor and the loading
            // spinner can paint in the meantime.
            Task { await r.reload() }
        }
        .onExitCommand { if !embedded { dismiss() } }
        // Belt-and-suspenders ESC handler. `.onExitCommand` works only
        // when the surrounding view holds focus, but the SwiftUI Table
        // grabs focus the moment it renders and swallows Escape before
        // it propagates back up. A hidden button with
        // `.keyboardShortcut(.cancelAction)` registers a window-wide
        // shortcut that the Table can't intercept.
        .background {
            if !embedded {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    /// Centered spinner + progress shown while `reload()` is building the
    /// plan. Visible from the moment the toolbar button is clicked until
    /// the table is populated.
    @ViewBuilder
    private func loadingView(model: RenameModel) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Building rename plan…")
                .font(.headline)
            if model.loadTotal > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text("\(model.loadProcessed) of \(model.loadTotal)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Scanning folders for subtitle files — this can take a moment on a network volume.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func content(model: RenameModel) -> some View {
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            if model.rows.isEmpty {
                emptyState
            } else {
                table(model: model)
            }
            Divider()
            footer(model: model)
        }
        .confirmationDialog(
            "Rename \(model.includedCount) file\(model.includedCount == 1 ? "" : "s")?",
            isPresented: $confirmingApply,
            titleVisibility: .visible
        ) {
            Button("Rename", role: .destructive) {
                Task { await model.apply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files and folders will be renamed and moved permanently. There is no undo.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(model: RenameModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename Library")
                        .font(.headline)
                    Text(summaryText(model: model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isApplying {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                }
            }

            // Live "currently renaming" line. Reserved height so the layout
            // doesn't jump when it appears/disappears.
            if let path = model.currentPath, model.isApplying {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Renaming:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func summaryText(model: RenameModel) -> String {
        let total = model.rows.count
        let selected = model.includedCount
        if total == 0 { return "Everything is already in canonical form." }
        return "\(total) file\(total == 1 ? "" : "s") would be renamed · \(selected) selected"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Nothing to rename")
                .font(.headline)
            Text("Every matched movie already follows the canonical naming convention, or hasn't been matched to TMDB yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Table

    @ViewBuilder
    private func table(model: RenameModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    Text("Proposed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    Text("Include")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.includeColumnWidth, alignment: .center)
                        .padding(.vertical, 6)
                }
                .background(.quaternary.opacity(0.3))
                Divider()

                ForEach(Array(model.rows.enumerated()), id: \.element.id) { idx, row in
                    rowView(row: row, isCurrent: model.currentIndex == idx, model: model)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(row: RenameModel.Row, isCurrent: Bool, model: RenameModel) -> some View {
        HStack(spacing: 0) {
            currentCell(for: row)
            Divider()
            proposedCell(for: row)
            Divider()
            Toggle("", isOn: Binding(
                get: { row.included },
                set: { newValue in model.setIncluded(newValue, for: row.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(model.isApplying || row.status == .succeeded)
            .frame(width: Self.includeColumnWidth, alignment: .center)
            .padding(.vertical, 8)
        }
        .background(rowBackground(row: row, isCurrent: isCurrent))
    }

    /// Left-hand cell: current video path + every subtitle file indented
    /// beneath it, plus the special-chars / Remux / loose chips on the
    /// video line. Mirrors the structure of `proposedCell` so the user
    /// can scan both sides line-by-line.
    @ViewBuilder
    private func currentCell(for row: RenameModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.currentDisplay)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.currentDisplay)
                if row.extraInfo != nil {
                    StatusChip(text: "extra", color: .pink)
                        .help("Bonus video the user flagged at Multi-Videos. Apply moves it into the parent movie's `Other/` subfolder and pulls any sibling sidecar subtitles along; Move to Library then records it in the `extras` table.")
                }
                if row.duplicateConflict {
                    StatusChip(text: "duplicate", color: .red)
                        .help("Another row targets the same canonical path (likely two source files matched to the same TMDB id). Unchecked by default — reconcile before Apply: delete the redundant copy or re-match one to a different movie.")
                }
                if row.hasQualitySuffix {
                    StatusChip(text: "multi-quality", color: .teal)
                        .help("Another row shares this row's TMDB id and edition slot, so a [<quality>] suffix has been appended to the filename (derived from ffprobe data) to keep the two on disk as distinct alternate-version files. Plex / Jellyfin group them under one library entry with a version picker.")
                }
                if row.hasSpecialCharacters {
                    StatusChip(text: "special chars", color: .orange)
                }
                if row.isRemux {
                    StatusChip(text: "Remux", color: .purple)
                }
                if row.plan == .createFolderAndMove {
                    StatusChip(text: "loose", color: .blue)
                }
            }
            ForEach(row.subtitles) { sub in
                Text(subtitleDisplayName(path: sub.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
            statusLine(row: row)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Right-hand cell: proposed folder + video file + every subtitle's
    /// proposed location, all in canonical form. Mirrors the structure of
    /// the current cell so the user can scan both sides line-by-line.
    /// Extras rows get one extra line for the `Other/` subfolder so the
    /// move target reads as `wrapper / Other / filename` — three
    /// indented lines instead of two.
    @ViewBuilder
    private func proposedCell(for row: RenameModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.extraInfo != nil {
                // For extras the path is `<wrapper>/Other/<filename>`;
                // splitting at the LAST slash would show
                // `<wrapper>/Other` as one folder line, hiding the
                // `Other/` boundary. Split twice so each level
                // renders on its own indent and the structure is
                // obvious at a glance.
                let parts = splitExtraProposedPath(row.proposedDisplay)
                Text("/" + parts.wrapper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("/" + parts.subfolder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                Text("/" + parts.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 24)
            } else {
                let (folder, filename) = splitProposedPath(row.proposedDisplay)
                Text("/" + folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("/" + filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
            }
            ForEach(row.subtitles) { sub in
                HStack(spacing: 4) {
                    Text("/" + subtitleDisplayName(path: sub.newPath))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    proposedSubtitleAnnotation(sub)
                }
                .padding(.leading, row.extraInfo == nil ? 12 : 24)
            }
        }
        .help(row.proposedDisplay)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Three-way split of an extras row's proposedDisplay into
    /// `<wrapper>/<subfolder>/<filename>`. Always uses the LAST two
    /// slashes — anything earlier collapses into the wrapper segment
    /// (defensive against future categories beyond `Other/`).
    private func splitExtraProposedPath(_ path: String)
        -> (wrapper: String, subfolder: String, filename: String)
    {
        guard let lastSlash = path.lastIndex(of: "/") else {
            return ("", "", path)
        }
        let filename = String(path[path.index(after: lastSlash)...])
        let head = String(path[..<lastSlash])
        guard let priorSlash = head.lastIndex(of: "/") else {
            return ("", head, filename)
        }
        let wrapper = String(head[..<priorSlash])
        let subfolder = String(head[head.index(after: priorSlash)...])
        return (wrapper, subfolder, filename)
    }

    /// Inline annotation rendered next to a proposed subtitle path —
    /// surfaces the `.N` collision suffix, soft warnings, and per-sub
    /// failure state. Visual cue only; the full text lives in the
    /// existing subtitle tooltip.
    @ViewBuilder
    private func proposedSubtitleAnnotation(_ sub: RenameModel.SubtitleAsset) -> some View {
        if sub.collisionSuffix {
            Text("·  collision-suffix")
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
        if sub.warningReason != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
        if sub.status == .failed {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
        if sub.status == .succeeded {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }

    /// Splits `<folder-portion>/<filename>` into its two halves. The
    /// folder portion may itself contain slashes (e.g. `Marvel/Avengers
    /// (2012) {tmdb-N}`) — that's fine, we only break on the final
    /// separator.
    private func splitProposedPath(_ path: String) -> (folder: String, filename: String) {
        guard let lastSlash = path.lastIndex(of: "/") else { return ("", path) }
        let folder = String(path[..<lastSlash])
        let filename = String(path[path.index(after: lastSlash)...])
        return (folder, filename)
    }

    @ViewBuilder
    private func statusLine(row: RenameModel.Row) -> some View {
        switch row.status {
        case .pending:
            EmptyView()
        case .succeeded:
            Label("Renamed", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Label(row.failureReason ?? "Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func rowBackground(row: RenameModel.Row, isCurrent: Bool) -> Color {
        if isCurrent { return Color.accentColor.opacity(0.12) }
        switch row.status {
        case .succeeded: return Color.green.opacity(0.06)
        case .failed:    return Color.red.opacity(0.06)
        case .pending:   return .clear
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(model: RenameModel) -> some View {
        HStack(spacing: 12) {
            Button(model.allIncluded ? "Deselect All" : "Select All") {
                model.setAllIncluded(!model.allIncluded)
            }
            .disabled(model.rows.isEmpty || model.isApplying)

            Button("Copy Preview") {
                copyPreview(rows: model.rows)
            }
            .disabled(model.rows.isEmpty)
            .help("Copy the whole table to the clipboard as plain text for review (e.g. paste into an LLM to vet)")

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer()

            Button(applyLabel(model: model)) {
                confirmingApply = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.rows.isEmpty || model.isApplying || model.includedCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func applyLabel(model: RenameModel) -> String {
        let n = model.includedCount
        return n > 0 ? "Apply (\(n))" : "Apply"
    }

    // MARK: - Subtitle chip helpers

    private func subtitleChipText(row: RenameModel.Row) -> String {
        let count = row.subtitles.count
        let failed = row.subtitles.filter { $0.status == .failed }.count
        if failed > 0 { return "\(count) sub\(count == 1 ? "" : "s") · \(failed) failed" }
        let warned = row.subtitles.filter { $0.warningReason != nil }.count
        if warned > 0 { return "\(count) sub\(count == 1 ? "" : "s") · \(warned) review" }
        return "\(count) sub\(count == 1 ? "" : "s")"
    }

    private func subtitleChipColor(row: RenameModel.Row) -> Color {
        let hasFailures = row.subtitles.contains { $0.status == .failed }
        if hasFailures { return .red }
        let allSucceeded = !row.subtitles.isEmpty
            && row.subtitles.allSatisfy { $0.status == .succeeded }
        if allSucceeded { return .green }
        let hasWarning = row.subtitles.contains { $0.warningReason != nil }
        if hasWarning { return .yellow }
        return .teal
    }

    /// Verbose tooltip listing every subtitle's old → new name, with
    /// language / forced / SDH tags and per-sub status. Shows the Subs/
    /// folder prefix on either side when applicable so consolidation
    /// moves (sibling → Subs/) are visually distinct.
    private func subtitleTooltip(row: RenameModel.Row) -> String {
        row.subtitles.map { sub in
            let oldDisplay = subtitleDisplayName(path: sub.path)
            let newDisplay = subtitleDisplayName(path: sub.newPath)
            var line = "\(oldDisplay) → \(newDisplay)"
            if let lang = sub.language { line += "  [\(lang)]" }
            if sub.isForced { line += " forced" }
            if sub.isSDH { line += " sdh" }
            if let warning = sub.warningReason { line += "\n  • \(warning)" }
            if let reason = sub.failureReason { line += "\n  ⚠️ \(reason)" }
            return line
        }.joined(separator: "\n")
    }

    /// Renders a subtitle path as `Subs/filename.ext` when the immediate
    /// parent is a Subs-style folder, otherwise just `filename.ext`.
    private func subtitleDisplayName(path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if SubtitleClassifier.isSubtitleFolderAlias(parent) {
            return "\(parent)/\(filename)"
        }
        return filename
    }

    // MARK: - Copy Preview

    /// Serializes every row + subtitle plan into a plain-text dump and
    /// puts it on the system clipboard. The format is intentionally
    /// boring (per-row blocks with named fields) so an LLM can scan it
    /// end-to-end without confusing layout.
    private func copyPreview(rows: [RenameModel.Row]) {
        let text = formatPreview(rows: rows)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatPreview(rows: [RenameModel.Row]) -> String {
        var lines: [String] = []
        let included = rows.filter { $0.included }.count
        lines.append("# Movie Stats — Rename Preview")
        lines.append("")
        lines.append("Canonical naming format: `Title (Year) {tmdb-N}/Title (Year) {tmdb-N}[ [Remux]].ext`")
        lines.append("Subtitle convention: sidecars and contents of `Subs/` (or aliases) consolidate into a canonical `Subs/`.")
        lines.append("")
        lines.append("Total rows: \(rows.count)  ·  Selected for apply: \(included)")
        lines.append("")

        for (idx, row) in rows.enumerated() {
            let status = row.included ? "[INCLUDE]" : "[SKIP]"
            lines.append("=== Row \(idx + 1) \(status) ===")
            lines.append("CURRENT:  \(row.currentDisplay)")
            lines.append("PROPOSED: \(row.proposedDisplay)")

            var flags: [String] = []
            if row.duplicateConflict { flags.append("DUPLICATE — same target as another row") }
            if row.hasQualitySuffix { flags.append("multi-quality — [qualityTag] appended") }
            if row.hasSpecialCharacters { flags.append("special chars") }
            if row.isRemux { flags.append("Remux") }
            if row.plan == .createFolderAndMove { flags.append("loose top-level (creates wrapper)") }
            if !flags.isEmpty {
                lines.append("FLAGS:    \(flags.joined(separator: ", "))")
            }

            if !row.subtitles.isEmpty {
                lines.append("SUBS (\(row.subtitles.count)):")
                for sub in row.subtitles {
                    let oldName = subtitleDisplayName(path: sub.path)
                    let newName = subtitleDisplayName(path: sub.newPath)
                    var subLine = "  • \(oldName)  →  \(newName)"
                    var tags: [String] = []
                    if let lang = sub.language { tags.append(lang) }
                    if sub.isForced { tags.append("forced") }
                    if sub.isSDH { tags.append("sdh") }
                    if !tags.isEmpty { subLine += "  [\(tags.joined(separator: " "))]" }
                    lines.append(subLine)
                    if let warning = sub.warningReason {
                        lines.append("    ⚠ WARN: \(warning)")
                    }
                    if let reason = sub.failureReason {
                        lines.append("    ✗ FAIL: \(reason)")
                    }
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

/// Small color-tinted capsule used in the Current column to flag noteworthy
/// rows at a glance (special chars, Remux source, loose top-level video).
private struct StatusChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }
}
