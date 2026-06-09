import SwiftUI

/// A window that lists folders whose subtrees contain no files. Checked
/// folders can be permanently deleted (along with any empty subfolders or
/// hidden cruft inside them).
struct EmptyFoldersView: View {
    /// Optional directory override for embedded use (e.g. the import
    /// wizard). When nil, falls back to the live `directory`.
    let scopedDirectory: String?
    /// When true, drops the window-style chrome (dismiss hook, fixed
    /// min-size) so the view can be embedded inside another container.
    let embedded: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model = EmptyFoldersModel()
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
        .background {
            if !embedded {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
        }
        .task { await model.scan(directory: directory) }
        .confirmationDialog(
            "Permanently delete \(model.selection.count) folder\(model.selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.cleanSelected(directory: directory) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. The folders will not be moved to the Trash.")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Empty Folders")
                    .font(.headline)
                Text("\(model.folders.count) empty folder\(model.folders.count == 1 ? "" : "s") in \(directory)")
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
        if model.folders.isEmpty {
            Spacer()
            Text(model.isScanning ? "Scanning…" : "No empty folders found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            List {
                ForEach(model.folders) { folder in
                    row(for: folder)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(for folder: EmptyFolder) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: selectionBinding(for: folder))
                .labelsHidden()
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .help(folder.path)
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
                Text("\(model.selection.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button(model.allSelected ? "Deselect All" : "Select All") {
                model.toggleSelectAll()
            }
            .disabled(model.folders.isEmpty || model.isDeleting)

            Button("Delete Selected") { confirmingDelete = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasSelection || model.isDeleting)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func selectionBinding(for folder: EmptyFolder) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(folder.path) },
            set: { isOn in
                if isOn {
                    model.selection.insert(folder.path)
                } else {
                    model.selection.remove(folder.path)
                }
            }
        )
    }
}
