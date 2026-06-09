import SwiftUI

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

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = DuplicatesModel()
    @State private var confirmingDelete = false

    init(scopedDirectory: String? = nil, embedded: Bool = false) {
        self.scopedDirectory = scopedDirectory
        self.embedded = embedded
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
        .task { await model.scan(directory: directory) }
        .confirmationDialog(
            "Permanently delete \(model.selection.count) file\(model.selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.cleanSelected(directory: directory) }
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
            Text(byteString(file.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(file.path)
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
                } else {
                    model.selection.remove(file.path)
                }
            }
        )
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
