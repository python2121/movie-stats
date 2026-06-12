import AppKit
import SwiftUI

/// Library health window: report categories on the left, findings on the
/// right. Deliberately a plain HStack layout — NavigationSplitView brings
/// document-app sidebar behavior (materials, toolbar overlap, collapse
/// affordances) that fights a simple utility window.
struct ReportsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var model = ReportsModel()
    @State private var selection: ReportsModel.Kind = .noEnglishSubs
    @State private var pendingDelete: ReportsModel.Row?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(ReportsModel.Kind.allCases) { kind in
                    HStack {
                        Label(kind.rawValue, systemImage: kind.systemImage)
                        Spacer()
                        Text("\(model.rows[kind]?.count ?? 0)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 250)

            Divider()

            reportDetail(selection)
        }
        .frame(minWidth: 880, minHeight: 480)
        .toolbar {
            ToolbarItem {
                Button {
                    model.refresh(movies: appModel.movies, store: appModel.store)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Recompute every report from the current library")
            }
        }
        .onAppear {
            model.refresh(movies: appModel.movies, store: appModel.store)
        }
        .onExitCommand { dismiss() }
        // The List grabs focus and swallows Escape before .onExitCommand
        // fires — same workaround as RenameView.
        .background(
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
        .confirmationDialog(
            "Permanently delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let row = pendingDelete {
                    deleteFile(row, kind: selection)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The file is removed immediately — network volumes have no Trash to recover from.")
        }
    }

    private func reportDetail(_ kind: ReportsModel.Kind) -> some View {
        let rows = model.rows[kind] ?? []
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.rawValue)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(rows.count) item\(rows.count == 1 ? "" : "s")")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if rows.isEmpty {
                Spacer()
                Label("Nothing found — all clear.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(rows) { row in
                    reportRow(row, kind: kind)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                // Fresh identity per report — without this the List is
                // reused across selections and keeps the previous report's
                // scroll offset.
                .id(kind)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportRow(_ row: ReportsModel.Row, kind: ReportsModel.Kind) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(row.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let size = row.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .help(row.path)
        .contextMenu {
            if kind != .vobsubOrphans {
                Button("Play in \(ExternalPlayer.playerName)") {
                    ExternalPlayer.play(path: row.path)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: row.path)]
                )
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.path, forType: .string)
            }
            if kind == .spaceSavers || kind == .duplicateMatches || kind == .vobsubOrphans {
                Divider()
                Button("Delete File…", role: .destructive) {
                    pendingDelete = row
                }
            }
        }
    }

    /// Permanent delete (no Trash on network volumes — the app's standing
    /// design), then patch the database and recompute the reports.
    private func deleteFile(_ row: ReportsModel.Row, kind: ReportsModel.Kind) {
        do {
            try FileManager.default.removeItem(atPath: row.path)
            if kind == .vobsubOrphans {
                try appModel.store?.deleteSubtitleFile(path: row.path)
            } else {
                try appModel.store?.deleteMovie(path: row.path)
                appModel.reloadFromStore()
            }
        } catch {
            appModel.lastError = "\(error)"
        }
        model.refresh(movies: appModel.movies, store: appModel.store)
    }
}
