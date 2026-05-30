import AppKit
import SwiftUI

/// A window listing every file of one category in the scanned directory, with
/// per-row checkboxes and a "Clean" action that permanently deletes the checked
/// files and refreshes the list. Used for both the Images and Text/NFO windows.
struct FileCleanupView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var model: FileCleanupModel
    @State private var confirmingDelete = false

    init(category: CleanupCategory) {
        self.category = category
        _model = State(initialValue: FileCleanupModel(category: category))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await model.scan(directory: app.directoryPath) }
        .confirmationDialog(
            "Permanently delete \(model.selection.count) \(category.noun)\(model.selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.cleanSelected(directory: app.directoryPath) }
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
                Text(category.title)
                    .font(.headline)
                Text("\(model.files.count) \(category.noun)\(model.files.count == 1 ? "" : "s") in \(app.directoryPath)")
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

    private var table: some View {
        Table(model.files) {
            TableColumn("") { file in
                Toggle("", isOn: selectionBinding(for: file))
                    .labelsHidden()
            }
            .width(28)

            TableColumn("Preview") { file in
                PreviewCell(path: file.path, kind: category.preview)
            }
            .width(56)

            TableColumn("File") { file in
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
                .help(file.path)
            }

            TableColumn("Size") { file in
                Text(byteString(file.size))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(90)
        }
        .overlay {
            if model.files.isEmpty && !model.isScanning {
                Text("No \(category.noun)s found.")
                    .foregroundStyle(.secondary)
            }
        }
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

            Button("Dismiss") { dismiss() }

            Button("Clean \(category.title)") { confirmingDelete = true }
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

/// Renders the per-row preview: an image thumbnail or a short text snippet,
/// loaded off the main actor.
private struct PreviewCell: View {
    let path: String
    let kind: CleanupCategory.PreviewKind

    @State private var image: NSImage?
    @State private var snippet: String?

    var body: some View {
        Group {
            switch kind {
            case .image:
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            case .text:
                if let snippet {
                    Text(snippet)
                        .font(.system(size: 6, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .task(id: path) {
            switch kind {
            case .image:
                image = await Task.detached(priority: .utility) {
                    Thumbnailer.thumbnail(forPath: path, maxPixel: 88)
                }.value
            case .text:
                snippet = await Task.detached(priority: .utility) {
                    TextPreview.snippet(forPath: path)
                }.value
            }
        }
    }
}
