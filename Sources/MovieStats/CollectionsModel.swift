import Foundation
import Observation

/// Franchise completeness: groups the library's matched movies by their TMDB
/// collection, then fetches each collection's full film list to show what's
/// missing. Results live in memory only — a fresh fetch per window open
/// keeps the data current without another cache to invalidate.
@MainActor
@Observable
final class CollectionsModel {
    struct Part: Identifiable, Hashable {
        let tmdbID: Int
        let title: String
        let year: String?
        let owned: Bool
        let released: Bool
        var id: Int { tmdbID }
    }

    struct Entry: Identifiable {
        let collectionID: Int
        let name: String
        var ownedCount: Int
        var parts: [Part] = []
        var releasedCount: Int { parts.filter(\.released).count }
        var isComplete: Bool { !parts.isEmpty && ownedCount >= releasedCount }
        var error: String?
        var id: Int { collectionID }
    }

    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    private(set) var progress = 0
    private(set) var total = 0

    func load(movies: [MovieFile]) async {
        let matched = movies.filter { $0.collectionID != nil }
        let grouped = Dictionary(grouping: matched, by: { $0.collectionID! })
        let ownedIDs = Set(movies.compactMap(\.tmdbId))

        entries = grouped.map { id, films in
            Entry(
                collectionID: id,
                name: films.first?.collectionName ?? "Collection \(id)",
                ownedCount: Set(films.compactMap(\.tmdbId)).count
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        isLoading = true
        total = entries.count
        progress = 0
        defer { isLoading = false }

        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        for idx in entries.indices {
            do {
                let detail = try await TMDBService.collection(forID: entries[idx].collectionID)
                entries[idx].parts = detail.parts
                    .map { part in
                        Part(
                            tmdbID: part.id,
                            title: part.title,
                            year: part.year,
                            owned: ownedIDs.contains(part.id),
                            released: (part.releaseDate.map { !$0.isEmpty && $0 <= today } ?? false)
                        )
                    }
                    .sorted { ($0.year ?? "9999") < ($1.year ?? "9999") }
                entries[idx].ownedCount = entries[idx].parts.filter(\.owned).count
            } catch {
                entries[idx].error = error.localizedDescription
            }
            progress += 1
        }
    }
}
