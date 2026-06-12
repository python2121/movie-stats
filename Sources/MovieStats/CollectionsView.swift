import AppKit
import SwiftUI

/// Franchise-completeness window: every TMDB collection the library touches,
/// with owned / missing entries per collection.
struct CollectionsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var model = CollectionsModel()
    @State private var onlyIncomplete = false

    private var visibleEntries: [CollectionsModel.Entry] {
        let sorted = model.entries.sorted {
            ($0.isComplete ? 1 : 0, $0.name) < (($1.isComplete ? 1 : 0), $1.name)
        }
        return onlyIncomplete ? sorted.filter { !$0.isComplete } : sorted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if model.isLoading {
                    ProgressView(value: Double(model.progress), total: Double(max(model.total, 1)))
                        .frame(width: 160)
                    Text("Fetching collections… \(model.progress)/\(model.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(summaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Only Incomplete", isOn: $onlyIncomplete)
                    .toggleStyle(.checkbox)
            }
            .padding(16)

            Divider()

            if model.entries.isEmpty && !model.isLoading {
                Spacer()
                Text("No matched movies belong to a TMDB collection yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(visibleEntries) { entry in
                        collectionRow(entry)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle("Collections")
        .task {
            await model.load(movies: appModel.movies)
        }
        .background(
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    private var summaryLine: String {
        let total = model.entries.count
        let incomplete = model.entries.filter { !$0.isComplete }.count
        guard total > 0 else { return "Franchises your matched movies belong to." }
        if incomplete == 0 { return "\(total) collections — all complete." }
        return "\(total) collections · \(incomplete) missing movies."
    }

    private func collectionRow(_ entry: CollectionsModel.Entry) -> some View {
        DisclosureGroup {
            ForEach(entry.parts) { part in
                partRow(part)
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } label: {
            HStack {
                Image(systemName: entry.isComplete ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(entry.isComplete ? Color.green : Color.secondary)
                Text(entry.name)
                    .font(.body.weight(.medium))
                Spacer()
                if !entry.parts.isEmpty {
                    Text("\(entry.ownedCount) of \(entry.releasedCount)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(entry.isComplete ? Color.secondary : Color.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func partRow(_ part: CollectionsModel.Part) -> some View {
        HStack(spacing: 8) {
            Image(systemName: part.owned ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(part.owned ? .green : .secondary)
            Text(part.title)
                .foregroundStyle(part.owned ? .primary : .secondary)
            if let year = part.year {
                Text("(\(year))")
                    .foregroundStyle(.secondary)
            }
            if !part.released {
                Text("unreleased")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !part.owned {
                Button("View on TMDB") {
                    NSWorkspace.shared.open(
                        URL(string: "https://www.themoviedb.org/movie/\(part.tmdbID)")!
                    )
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.leading, 4)
    }
}
