import SwiftUI

/// Wires the import wizard's "Mark as Extra" behavior into
/// `DuplicatesView` without making the standalone Multiple-Videos
/// tool know about import sessions. Set by `ImportView` only; nil
/// for the standalone window.
struct DuplicatesExtrasConfig {
    /// True iff the file is eligible to be marked Extra — typically
    /// "has a TMDB-matched larger sibling in the same bucket." Drives
    /// whether the Extra checkbox renders for this row.
    var isMarkable: (ScannedFile) -> Bool
    /// Whether the user has currently checked Extra for this file.
    var isMarked: (ScannedFile) -> Bool
    /// Toggle the Extra mark. The view layers mutual exclusion with
    /// the delete checkbox on top — that logic doesn't live here.
    var setMarked: (ScannedFile, Bool) -> Void
}

/// A window that lists folders containing more than one video file. Videos are
/// grouped under their top-level folder (even when nested in different
/// subfolders) so it's clear which belong together. Checked videos can be
/// permanently deleted.
struct DuplicatesView: View {
    /// Optional directory override (for embedded use by the import
    /// wizard). When nil, falls back to the live `directory`.
    let scopedDirectory: String?
    /// Drops window-style chrome (dismiss, fixed min-size) when true.
    let embedded: Bool
    /// When true, videos sitting directly at the scan root are bucketed
    /// into a synthetic group keyed by the root itself. Used by the
    /// import wizard, whose scan root IS a single movie's folder — so
    /// loose top-level MKVs (main movie + extras like
    /// "The.Cast.Remembers.mkv") are exactly what the user wants to
    /// see and prune from.
    let includeRootLevel: Bool
    /// Optional Extras-column plumbing. nil in the standalone window
    /// (no Extra column rendered); non-nil when embedded in the
    /// import wizard's Multiple Videos step.
    let extrasConfig: DuplicatesExtrasConfig?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = DuplicatesModel()
    @State private var confirmingDelete = false

    init(
        scopedDirectory: String? = nil,
        embedded: Bool = false,
        includeRootLevel: Bool = false,
        extrasConfig: DuplicatesExtrasConfig? = nil
    ) {
        self.scopedDirectory = scopedDirectory
        self.embedded = embedded
        self.includeRootLevel = includeRootLevel
        self.extrasConfig = extrasConfig
    }

    private var directory: String {
        scopedDirectory ?? app.directoryPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: embedded ? nil : 600, minHeight: embedded ? nil : 460)
        .onExitCommand { if !embedded { dismiss() } }
        .background {
            if !embedded {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .task { await model.scan(directory: directory, includeRootLevel: includeRootLevel) }
        .confirmationDialog(
            "Permanently delete \(model.selection.count) file\(model.selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.cleanSelected(directory: directory, includeRootLevel: includeRootLevel) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. The files will not be moved to the Trash.")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Multiple Videos per Folder")
                    .font(.headline)
                Text("\(model.groups.count) folder\(model.groups.count == 1 ? "" : "s") with more than one video in \(directory)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if model.groups.isEmpty {
            Spacer()
            Text(model.isScanning ? "Scanning…" : "No folders with multiple videos found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.files) { file in
                            row(for: file)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.secondary)
                            Text(group.name)
                                .fontWeight(.semibold)
                            Text("\(group.files.count) videos")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(model.allButLargestSelected(in: group) ? "Deselect All" : "Select All") {
                                model.toggleSelectAllButLargest(in: group)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(model.isDeleting)
                            .help("Select every video in this folder except the largest")
                        }
                        .help(group.directory)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(for file: ScannedFile) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: selectionBinding(for: file))
                .labelsHidden()
                .help("Permanently delete this file when you click Delete Selected.")
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
            if let config = extrasConfig {
                extraCell(for: file, config: config)
            }
            Text(byteString(file.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(file.path)
    }

    /// Per-row "Mark as Extra" cell. Always rendered (when
    /// `extrasConfig` is set) so the column never disappears — even
    /// in single-video imports where no row is eligible to be marked.
    /// Ineligible rows show the toggle disabled with a tooltip
    /// explaining why; eligible rows show it as a working checkbox.
    @ViewBuilder
    private func extraCell(for file: ScannedFile, config: DuplicatesExtrasConfig) -> some View {
        let markable = config.isMarkable(file)
        Toggle(
            "Extra",
            isOn: markable
                ? extrasBinding(for: file, config: config)
                : .constant(false)
        )
        .toggleStyle(.checkbox)
        .disabled(!markable)
        .help(markable
              ? "Move this file into the parent movie's `Other/` subfolder when the import completes, and record it in the library database. Mutually exclusive with the Delete checkbox."
              : "Marking this as an Extra needs a larger TMDB-matched sibling video in the same bucket — that sibling becomes the parent movie the extra is attached to.")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isDeleting {
                ProgressView(value: model.deleteProgress)
                    .frame(width: 180)
                Text("Deleting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            if model.hasSelection {
                Text("\(model.selection.count) selected · \(byteString(model.selectedSize))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(model.allSelected ? "Deselect All" : "Select All") {
                model.toggleSelectAll()
            }
            .disabled(model.fileCount == 0 || model.isDeleting)

            Button("Delete Selected") { confirmingDelete = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasSelection || model.isDeleting)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func selectionBinding(for file: ScannedFile) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(file.path) },
            set: { isOn in
                if isOn {
                    model.selection.insert(file.path)
                    // Mutual exclusion: marking for deletion clears
                    // any Extra mark (a deleted file can't also be
                    // routed to Other/).
                    extrasConfig?.setMarked(file, false)
                } else {
                    model.selection.remove(file.path)
                }
            }
        )
    }

    /// Two-way binding for the per-row Extra checkbox. Mirrors the
    /// selection binding's mutual-exclusion contract — checking Extra
    /// clears the delete selection for the same file.
    private func extrasBinding(for file: ScannedFile, config: DuplicatesExtrasConfig) -> Binding<Bool> {
        Binding(
            get: { config.isMarked(file) },
            set: { isOn in
                config.setMarked(file, isOn)
                if isOn {
                    model.selection.remove(file.path)
                }
            }
        )
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
