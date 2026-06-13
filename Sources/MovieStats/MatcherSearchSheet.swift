import SwiftUI

/// In-window sheet for picking a different TMDB result when the auto-match
/// guessed wrong. Pre-fills the search field with the parsed title, lets the
/// user edit and re-search, then calls back with the chosen result.
struct MatcherSearchSheet: View {
    let row: MatcherModel.Row
    /// Callback fired when the user clicks a result. The second argument
    /// is the optional edition label they typed (nil / empty when they
    /// left the field blank — the typical case). Edition flows into the
    /// canonical filename as `{edition-<value>}` so multiple cuts of
    /// the same TMDB id coexist as alternate versions under one
    /// Plex/Jellyfin wrapper.
    let onPick: (TMDBMovie, String?) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var customEdition: String = ""
    @State private var results: [TMDBMovie] = []
    @State private var isSearching = false
    @State private var lastError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            editionInput
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 580)
        .onAppear {
            query = row.parsedTitle.isEmpty ? row.displayTitle : row.parsedTitle
            customEdition = row.customEdition ?? ""
            searchFocused = true
            Task { await runSearch() }
        }
        .onExitCommand { onCancel() }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pick a TMDB match")
                .font(.headline)
            Text(row.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search TMDB…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { Task { await runSearch() } }
            Button("Search") {
                Task { await runSearch() }
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Optional edition label. Anything typed here is sent to the
    /// matcher with the picked candidate; the renamer then emits it as
    /// `{edition-<value>}` in the canonical filename. Use for fan
    /// edits, alternate cuts, or restoration projects (e.g. "4K77 v1.4",
    /// "Director's Cut", "Despecialized v2.7"). Leave blank for the
    /// vast majority of rows.
    private var editionInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Custom edition (optional) — e.g. 4K77 v1.4 or Director's Cut",
                          text: $customEdition)
                    .textFieldStyle(.plain)
                Text("Written into the canonical filename as {edition-<value>}. Leave blank for the standard release.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lastError {
            Label(lastError, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            Text("No matches — try editing the query above.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        resultRow(result)
                        Divider()
                    }
                }
            }
        }
    }

    private func resultRow(_ result: TMDBMovie) -> some View {
        Button {
            let trimmed = customEdition.trimmingCharacters(in: .whitespacesAndNewlines)
            onPick(result, trimmed.isEmpty ? nil : trimmed)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(result.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let year = result.year {
                            Text("(\(year))")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let avg = result.voteAverage, let count = result.voteCount, count > 0 {
                            Text(String(format: "%.1f", avg))
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let overview = result.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    Text("TMDB ID \(result.id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Search

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        lastError = nil
        defer { isSearching = false }
        do {
            results = try await TMDBService.searchMovies(title: trimmed, year: nil)
        } catch {
            results = []
            lastError = error.localizedDescription
        }
    }
}
