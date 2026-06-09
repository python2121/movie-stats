import SwiftUI

/// "Match Library to TMDB" window. Lists every unmatched movie on the left,
/// TMDB auto-match result on the right (clickable to override), Scan +
/// Confirm at the bottom.
struct MatcherView: View {
    /// Optional scope override. When set, the matcher is constructed
    /// against this scope (e.g. an `ImportSession`) instead of the
    /// live `appModel`. Set by the import wizard.
    let scopedScope: (any MovieScope)?
    /// Drops window-style chrome (dismiss hook, fixed min-size) when
    /// true — for embedding inside another container.
    let embedded: Bool

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var matcher: MatcherModel?
    @State private var editingRow: MatcherModel.Row?

    init(scopedScope: (any MovieScope)? = nil, embedded: Bool = false) {
        self.scopedScope = scopedScope
        self.embedded = embedded
    }

    /// Width of the right-hand include checkbox column. Same value used by
    /// both the header cell and each row's checkbox so they stay aligned.
    private static let includeColumnWidth: CGFloat = 80

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
                matcher = MatcherModel(scope: scopedScope ?? appModel)
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
                onPick: { pick in
                    matcher?.setCandidate(pick, for: row.id)
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
        }
        .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear)
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
                Task { await model.confirm() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                model.rows.isEmpty
                    || model.isScanning
                    || model.isConfirming
                    || model.rows.allSatisfy { !$0.included }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Confirm button text — appends the included count so the user can see
    /// at a glance how many rows are about to be written this pass.
    private func confirmLabel(model: MatcherModel) -> String {
        let count = model.rows.filter { $0.included }.count
        return count > 0 ? "Confirm (\(count))" : "Confirm"
    }
}
