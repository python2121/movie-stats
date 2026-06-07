import SwiftUI

/// "Rename Library" window. Three-column table with current path, proposed
/// path, and include checkbox. Special-character rows float to the top.
/// Apply runs serially with a live "currently renaming" status.
struct RenameView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var renamer: RenameModel?
    @State private var confirmingApply = false

    /// Width of the right-hand checkbox column. Same value used by the
    /// header cell and each row to keep things aligned.
    private static let includeColumnWidth: CGFloat = 80

    var body: some View {
        Group {
            if let renamer {
                content(model: renamer)
                    .environment(renamer)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        .onAppear {
            if renamer == nil {
                renamer = RenameModel(appModel: appModel)
            }
            if let r = renamer, !r.isApplying {
                r.reload()
            }
        }
        .onExitCommand { dismiss() }
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.currentDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.currentDisplay)
                    if row.hasSpecialCharacters {
                        StatusChip(text: "special chars", color: .orange)
                    }
                    if row.isRemux {
                        StatusChip(text: "Remux", color: .purple)
                    }
                    if row.plan == .createFolderAndMove {
                        StatusChip(text: "loose", color: .blue)
                    }
                    if !row.subtitles.isEmpty {
                        StatusChip(
                            text: subtitleChipText(row: row),
                            color: subtitleChipColor(row: row)
                        )
                        .help(subtitleTooltip(row: row))
                    }
                }
                statusLine(row: row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(row.proposedDisplay)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.proposedDisplay)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

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
        return "\(count) sub\(count == 1 ? "" : "s")"
    }

    private func subtitleChipColor(row: RenameModel.Row) -> Color {
        let hasFailures = row.subtitles.contains { $0.status == .failed }
        if hasFailures { return .red }
        let allSucceeded = !row.subtitles.isEmpty
            && row.subtitles.allSatisfy { $0.status == .succeeded }
        if allSucceeded { return .green }
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
