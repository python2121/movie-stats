import SwiftUI

/// "Match Library to TMDB" window. Lists every unmatched movie on the left,
/// TMDB auto-match result on the right (clickable to override), Scan +
/// Confirm at the bottom.
/// Wires the import wizard's "Replace existing copy" behavior into
/// `MatcherView` without making the standalone library matcher know
/// about import sessions. Set by `ImportView` only; nil for the
/// standalone window.
struct MatcherReplaceConfig {
    /// True iff this row's currently-selected candidate matches a
    /// movie already in the live library (same TMDB id AND same
    /// custom edition slot). Drives whether the Replace cell renders
    /// a checkbox or stays blank.
    var isReplaceable: (MatcherModel.Row) -> Bool
    /// Whether the user has currently checked Replace for this row.
    var isMarked: (MatcherModel.Row) -> Bool
    /// Toggle the user's Replace choice for one row.
    var setMarked: (MatcherModel.Row, Bool) -> Void
}

struct MatcherView: View {
    /// Optional scope override. When set, the matcher is constructed
    /// against this scope (e.g. an `ImportSession`) instead of the
    /// live `appModel`. Set by the import wizard.
    let scopedScope: (any MovieScope)?
    /// Drops window-style chrome (dismiss hook, fixed min-size) when
    /// true — for embedding inside another container.
    let embedded: Bool
    /// Optional Replace-column plumbing. nil in the standalone library
    /// matcher; non-nil when embedded in the import wizard's Match
    /// step. When set, the table grows a "Replace" column at the end
    /// that fires per-row checkboxes for the import's duplicate
    /// conflicts.
    let replaceConfig: MatcherReplaceConfig?

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var matcher: MatcherModel?
    @State private var editingRow: MatcherModel.Row?
    /// Per-row Replace marks for the **standalone** library matcher
    /// (when this view isn't embedded in the import wizard). Empty in
    /// import mode — there the marks live on the ImportSession and
    /// reach us via `replaceConfig`.
    @State private var standaloneReplaceMarks: Set<String> = []
    /// Drives the standalone Replace confirmation sheet that fires
    /// when the user clicks Confirm with at least one row marked
    /// Replace.
    @State private var showStandaloneReplaceConfirm = false

    init(
        scopedScope: (any MovieScope)? = nil,
        embedded: Bool = false,
        replaceConfig: MatcherReplaceConfig? = nil
    ) {
        self.scopedScope = scopedScope
        self.embedded = embedded
        self.replaceConfig = replaceConfig
    }

    /// True when this is the standalone "Match Library to TMDB" window —
    /// not embedded in another scope, no externally-supplied replace
    /// config. The view auto-builds its own Replace plumbing in this
    /// mode.
    private var isStandaloneMatcher: Bool {
        scopedScope == nil && replaceConfig == nil
    }

    /// The replace plumbing actually used by the table — caller-supplied
    /// in import mode, auto-built from `appModel` + local marks in
    /// standalone mode. Read this everywhere instead of the raw
    /// `replaceConfig`.
    private var effectiveReplaceConfig: MatcherReplaceConfig? {
        if let replaceConfig { return replaceConfig }
        if isStandaloneMatcher { return makeStandaloneReplaceConfig() }
        return nil
    }

    /// Builds the standalone Replace config: isReplaceable checks the
    /// live library for a same-`(tmdbId, customEdition)` entry other
    /// than the row's own file; mark state reads/writes
    /// `standaloneReplaceMarks` via the @State binding.
    private func makeStandaloneReplaceConfig() -> MatcherReplaceConfig {
        let marksBinding = $standaloneReplaceMarks
        let appModelRef = appModel
        return MatcherReplaceConfig(
            isReplaceable: { row in
                guard let candidate = row.candidate else { return false }
                let rowEdition = Self.editionSlot(row.customEdition)
                return appModelRef.movies.contains { existing in
                    existing.path != row.path
                        && existing.tmdbId == candidate.id
                        && Self.editionSlot(existing.customEdition) == rowEdition
                }
            },
            isMarked: { row in marksBinding.wrappedValue.contains(row.path) },
            setMarked: { row, value in
                if value {
                    marksBinding.wrappedValue.insert(row.path)
                } else {
                    marksBinding.wrappedValue.remove(row.path)
                }
            }
        )
    }

    /// Normalizes a custom edition into the slot key — trim + lower,
    /// matching `ImportSession.slotEdition` so duplicate detection
    /// stays consistent across the two flows.
    private static func editionSlot(_ edition: String?) -> String {
        (edition ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Width of the right-hand include checkbox column. Same value used by
    /// both the header cell and each row's checkbox so they stay aligned.
    private static let includeColumnWidth: CGFloat = 80
    /// Width of the Replace column when present. Slightly wider than
    /// the Include column because the header text reads longer.
    private static let replaceColumnWidth: CGFloat = 90

    var body: some View {
        Group {
            if let matcher {
                content(model: matcher)
                    .environment(matcher)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: embedded ? nil : 760, minHeight: embedded ? nil : 480)
        .onAppear {
            if matcher == nil {
                // Embedded mode (import wizard) auto-commits each
                // pick so downstream wizard steps see the tmdbId
                // without needing an explicit matcher-Confirm click.
                // Standalone library matcher leaves it off — Confirm
                // is the user's atomic checkpoint there.
                matcher = MatcherModel(
                    scope: scopedScope ?? appModel,
                    autoCommitOnPick: scopedScope != nil
                )
            }
            // Re-parse the file-title list from the AppModel every time the
            // window appears so a fresh rescan picks up renames / new files
            // / newly-matched files. Skip mid-operation so a re-appear can't
            // nuke an active scan/confirm.
            if let m = matcher, !m.isScanning, !m.isConfirming {
                m.reload()
            }
        }
        .sheet(item: $editingRow) { row in
            MatcherSearchSheet(
                row: row,
                onPick: { pick, edition in
                    matcher?.setCandidate(pick, customEdition: edition, for: row.id)
                    editingRow = nil
                },
                onCancel: { editingRow = nil }
            )
        }
        .onExitCommand { if !embedded { dismiss() } }
        .background {
            if !embedded {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
    }

    @ViewBuilder
    private func content(model: MatcherModel) -> some View {
        VStack(spacing: 0) {
            header(model: model)
            Divider()
            if !model.hasAPIKey {
                noKeyState
            } else if model.rows.isEmpty {
                emptyState
            } else {
                table(model: model)
            }
            Divider()
            footer(model: model)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(model: MatcherModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Match Library to TMDB")
                    .font(.headline)
                Text("\(model.rows.count) unmatched movie\(model.rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning || model.isConfirming {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Body states

    private var noKeyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No TMDB API key configured")
                .font(.headline)
            Text("Open MovieStats → TMDB API Key… to paste your key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Every movie is matched")
                .font(.headline)
            Text("No work to do here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table

    @ViewBuilder
    private func table(model: MatcherModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("File title (year)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                    Text("TMDB match")
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
                    if effectiveReplaceConfig != nil {
                        Divider()
                        Text("Replace")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.replaceColumnWidth, alignment: .center)
                            .padding(.vertical, 6)
                            .help(isStandaloneMatcher
                                  ? "Check to permanently delete a library copy that already matches this TMDB id + edition. The Confirm button will prompt before deletion. Only available for rows whose selected TMDB candidate already exists elsewhere in the library."
                                  : "Check to mark the matching library copy for permanent deletion when this import is moved to the library. Only available for rows whose selected TMDB candidate (and custom edition) already exists in the library.")
                    }
                }
                .background(.quaternary.opacity(0.3))
                Divider()

                ForEach(Array(model.rows.enumerated()), id: \.element.id) { idx, row in
                    rowView(row: row, isCurrent: model.currentIndex == idx)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(row: MatcherModel.Row, isCurrent: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.isExactMatch ? Color.green : Color.primary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            Button {
                editingRow = row
            } label: {
                rightCell(for: row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to pick a different TMDB result")

            Divider()

            Toggle("", isOn: Binding(
                get: { row.included },
                set: { newValue in matcher?.setIncluded(newValue, for: row.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(row.candidate == nil)
            .frame(width: Self.includeColumnWidth, alignment: .center)
            .padding(.vertical, 8)
            .help(row.candidate == nil
                  ? "Pick a TMDB match first to include this row"
                  : "Include this row when you click Confirm")

            if let cfg = effectiveReplaceConfig {
                Divider()
                replaceCell(for: row, config: cfg)
            }
        }
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
    }

    /// Renders the Replace column cell. Shows a checkbox bound to the
    /// import session's per-row Replace marks when the row's
    /// candidate matches an existing library entry; otherwise the
    /// cell is blank so the user has no ambiguous "is this checkbox
    /// meaningful?" moment.
    @ViewBuilder
    private func replaceCell(for row: MatcherModel.Row, config: MatcherReplaceConfig) -> some View {
        Group {
            if config.isReplaceable(row) {
                Toggle("", isOn: Binding(
                    get: { config.isMarked(row) },
                    set: { newValue in config.setMarked(row, newValue) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(isStandaloneMatcher
                      ? "Permanently delete the matching library copy (video + sidecars + wrapper folder) when you click Confirm. A confirmation dialog will list the targets before the deletion happens."
                      : "Delete the matching library copy (video + sidecars + wrapper folder) when this import moves over. The Match step's Next button will surface a confirmation dialog before you can advance.")
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
                    .help(row.candidate == nil
                          ? "No TMDB candidate yet"
                          : "No existing copy of this movie + edition in the library")
            }
        }
        .frame(width: Self.replaceColumnWidth, alignment: .center)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rightCell(for row: MatcherModel.Row) -> some View {
        if let candidate = row.candidate {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.candidateDisplayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(row.isExactMatch ? Color.green : Color.primary)
                Text("TMDB \(candidate.id)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if row.status == .failed {
            Label(row.failureReason ?? "No match", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(model: MatcherModel) -> some View {
        HStack(spacing: 12) {
            Button(model.allSelectableIncluded ? "Deselect All" : "Select All") {
                model.setAllIncluded(!model.allSelectableIncluded)
            }
            .disabled(
                model.selectableCount == 0
                    || model.isScanning
                    || model.isConfirming
            )

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer()

            if model.isScanning {
                Button("Cancel Scan") { model.cancelScan() }
            } else {
                Button("Scan") {
                    model.startScan()
                }
                .disabled(model.rows.isEmpty || model.isConfirming || !model.hasAPIKey)
            }

            Button(confirmLabel(model: model)) {
                handleConfirmTap(model: model)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                model.rows.isEmpty
                    || model.isScanning
                    || model.isConfirming
                    || model.rows.allSatisfy { !$0.included }
            )
            .confirmationDialog(
                standaloneReplaceDialogTitle(),
                isPresented: $showStandaloneReplaceConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete & Confirm Matches", role: .destructive) {
                    Task { await runStandaloneReplaceThenConfirm(model: model) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(standaloneReplaceDialogMessage())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Confirm-button handler. In standalone mode with at least one row
    /// marked Replace, surface a confirmation sheet before doing
    /// anything destructive; otherwise pass straight through to
    /// `matcher.confirm()` (the existing happy path).
    private func handleConfirmTap(model: MatcherModel) {
        // Auto-prune stale marks: rows the user may have un-picked a
        // candidate for since marking, or rows whose underlying file
        // moved out from under us. Keeps the dialog accurate.
        let validRowPaths = Set(model.rows.map { $0.path })
        standaloneReplaceMarks.formIntersection(validRowPaths)

        if isStandaloneMatcher && !standaloneReplacementTargets().isEmpty {
            showStandaloneReplaceConfirm = true
        } else {
            Task { await model.confirm() }
        }
    }

    /// Library files marked for deletion by the standalone Replace
    /// flow. For each row checked Replace, finds every library entry
    /// with the same `(tmdbId, customEdition)` slot (excluding the
    /// row's own file), deduped by path.
    private func standaloneReplacementTargets() -> [MovieFile] {
        guard let matcher else { return [] }
        var targets: [MovieFile] = []
        var seen = Set<String>()
        for row in matcher.rows where standaloneReplaceMarks.contains(row.path) {
            guard let candidate = row.candidate else { continue }
            let rowEdition = Self.editionSlot(row.customEdition)
            for libraryMovie in appModel.movies {
                guard libraryMovie.path != row.path,
                      libraryMovie.tmdbId == candidate.id,
                      Self.editionSlot(libraryMovie.customEdition) == rowEdition,
                      !seen.contains(libraryMovie.path)
                else { continue }
                seen.insert(libraryMovie.path)
                targets.append(libraryMovie)
            }
        }
        return targets
    }

    /// Standalone-replace dialog title — count of files about to be
    /// permanently deleted.
    private func standaloneReplaceDialogTitle() -> String {
        let count = standaloneReplacementTargets().count
        return "Permanently delete \(count) existing library file\(count == 1 ? "" : "s")?"
    }

    /// Standalone-replace dialog body — itemizes the first 8 targets
    /// by filename, summarizes the rest, and reminds the user it's
    /// irreversible.
    private func standaloneReplaceDialogMessage() -> String {
        let targets = standaloneReplacementTargets()
        let shown = targets.prefix(8).map { "• \($0.filename)" }.joined(separator: "\n")
        let suffix = targets.count > 8 ? "\n…and \(targets.count - 8) more" : ""
        return """
        These library files will be permanently deleted before the new matches are written:

        \(shown)\(suffix)

        This action cannot be undone.
        """
    }

    /// Standalone-replace OK action. Runs the deletions through the
    /// shared `AppModel.deleteLibraryCopies`, surfaces any failures on
    /// the matcher's error line, clears the marks, then commits the
    /// matches via `matcher.confirm()`.
    private func runStandaloneReplaceThenConfirm(model: MatcherModel) async {
        let targets = standaloneReplacementTargets()
        let failures = await appModel.deleteLibraryCopies(targets)
        if !failures.isEmpty {
            model.lastError = "Couldn't remove some existing copies:\n"
                + failures.joined(separator: "\n")
        }
        standaloneReplaceMarks.removeAll()
        await model.confirm()
    }

    /// Confirm button text — appends the included count so the user can see
    /// at a glance how many rows are about to be written this pass.
    private func confirmLabel(model: MatcherModel) -> String {
        let count = model.rows.filter { $0.included }.count
        return count > 0 ? "Confirm (\(count))" : "Confirm"
    }
}
