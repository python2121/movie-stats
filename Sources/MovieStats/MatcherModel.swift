import Foundation

/// Backs the "Match Library to TMDB" window. Builds a working table of every
/// unmatched movie, scans them top-to-bottom against TMDB, lets the user
/// override picks via a manual-search sheet, then writes everything to the
/// database on confirm (full detail + cached poster).
@MainActor
@Observable
final class MatcherModel {
    /// One row in the matcher table.
    struct Row: Identifiable {
        let path: String
        let displayTitle: String
        let parsedTitle: String
        let parsedYear: Int?
        var candidate: TMDBMovie?
        var status: Status = .pending
        var failureReason: String?
        /// Whether this row will be written on Confirm. Lets the user work
        /// through a long list in batches — leave unchecked rows for later.
        var included: Bool = false

        var id: String { path }

        /// True when the TMDB candidate's "Title (Year)" string equals the
        /// file's parsed displayTitle exactly — used by the matcher to
        /// highlight high-confidence picks in green.
        var isExactMatch: Bool {
            guard let candidate else { return false }
            return candidate.displayTitle == displayTitle
        }

        enum Status: Equatable {
            case pending     // not yet attempted
            case matched     // candidate is set
            case failed      // tried, no result
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isScanning = false
    private(set) var isConfirming = false
    /// 0...1 progress for the active scan or confirm operation.
    private(set) var progress: Double = 0
    /// Index of the row currently being worked on (for highlighting).
    private(set) var currentIndex: Int?
    var lastError: String?

    /// True iff every row has a candidate ready to be written on confirm.
    var allMatched: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.candidate != nil }
    }

    /// True iff TMDB lookups are even possible right now.
    var hasAPIKey: Bool { TMDBService.apiKey != nil }

    private let appModel: AppModel
    private var scanTask: Task<Void, Never>?

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    /// Rebuilds `rows` from the AppModel's current unmatched movies. Call
    /// each time the window is opened so we pick up newly-scanned files.
    func reload() {
        rows = appModel.movies
            .filter { $0.tmdbId == nil }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            .map { movie in
                Row(
                    path: movie.path,
                    displayTitle: movie.displayTitle,
                    parsedTitle: movie.parsedTitle,
                    parsedYear: movie.parsedYear
                )
            }
        progress = 0
        currentIndex = nil
        lastError = nil
    }

    // MARK: - Scan

    func startScan() {
        guard !isScanning, !isConfirming, !rows.isEmpty else { return }
        scanTask = Task { await scanAll() }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentIndex = nil
    }

    private func scanAll() async {
        isScanning = true
        defer {
            isScanning = false
            currentIndex = nil
        }
        let total = rows.count
        for index in rows.indices {
            if Task.isCancelled { return }
            currentIndex = index
            progress = total > 0 ? Double(index) / Double(total) : 0

            let row = rows[index]
            let queryTitle = row.parsedTitle.isEmpty
                ? row.displayTitle
                : row.parsedTitle
            do {
                let results = try await TMDBService.searchMovies(
                    title: queryTitle,
                    year: row.parsedYear
                )
                if let first = results.first {
                    rows[index].candidate = first
                    rows[index].status = .matched
                    rows[index].failureReason = nil
                    // Only auto-include exact matches; everything else
                    // waits for explicit user review.
                    rows[index].included = rows[index].isExactMatch
                } else {
                    rows[index].candidate = nil
                    rows[index].status = .failed
                    rows[index].failureReason = "No TMDB result"
                    rows[index].included = false
                }
            } catch {
                rows[index].candidate = nil
                rows[index].status = .failed
                rows[index].failureReason = error.localizedDescription
                rows[index].included = false
            }
        }
        progress = 1
    }

    // MARK: - Manual override

    /// Replaces the candidate for one row with a manually-picked TMDB result.
    /// Manual picks count as explicit endorsement, so they're auto-included.
    func setCandidate(_ candidate: TMDBMovie, for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].candidate = candidate
        rows[idx].status = .matched
        rows[idx].failureReason = nil
        rows[idx].included = true
    }

    /// Removes the candidate from a row (e.g. user clears it before
    /// re-running the manual search).
    func clearCandidate(for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].candidate = nil
        rows[idx].status = .pending
        rows[idx].failureReason = nil
        rows[idx].included = false
    }

    /// Sets the include flag for one row from the checkbox column.
    func setIncluded(_ included: Bool, for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].included = included
    }

    /// Bulk include/exclude — only touches rows that actually have a
    /// candidate, since rows without one can't be confirmed anyway.
    func setAllIncluded(_ included: Bool) {
        for idx in rows.indices where rows[idx].candidate != nil {
            rows[idx].included = included
        }
    }

    /// Number of rows currently eligible to be toggled (i.e. have a candidate).
    var selectableCount: Int {
        rows.lazy.filter { $0.candidate != nil }.count
    }

    /// True when every row that *can* be included currently is. Drives the
    /// Select All / Deselect All button's label + action.
    var allSelectableIncluded: Bool {
        let selectable = rows.filter { $0.candidate != nil }
        guard !selectable.isEmpty else { return false }
        return selectable.allSatisfy { $0.included }
    }

    // MARK: - Confirm

    /// For each row with a candidate: fetches the full TMDB detail (if we
    /// don't already have it cached), downloads the poster, writes the
    /// detail + the per-file match, then refreshes the AppModel's in-memory
    /// list so the main UI updates.
    func confirm() async {
        guard !isConfirming, !isScanning else { return }
        let matched = rows.compactMap { row -> (path: String, candidate: TMDBMovie)? in
            guard row.included, let candidate = row.candidate else { return nil }
            return (row.path, candidate)
        }
        guard !matched.isEmpty else { return }

        isConfirming = true
        progress = 0
        currentIndex = nil
        lastError = nil
        defer { isConfirming = false }

        var detailCache: [Int: TMDBMovieDetail] = [:]
        let total = matched.count

        for (offset, entry) in matched.enumerated() {
            if Task.isCancelled { break }
            currentIndex = rows.firstIndex(where: { $0.path == entry.path })
            progress = Double(offset) / Double(total)

            let tmdbID = entry.candidate.id
            do {
                let detail: TMDBMovieDetail
                if let cached = detailCache[tmdbID] {
                    detail = cached
                } else if let existing = try? appModel.store?.tmdbDetail(forID: tmdbID) {
                    // Already have this TMDB row from a previous confirm.
                    detail = existing
                    detailCache[tmdbID] = existing
                } else {
                    detail = try await TMDBService.details(forID: tmdbID)
                    try appModel.store?.upsertTMDBDetail(detail)
                    detailCache[tmdbID] = detail
                }

                // Cache poster art on disk (no-op if already there).
                await PosterCache.downloadIfNeeded(
                    tmdbID: tmdbID,
                    posterPath: detail.posterPath
                )

                try appModel.store?.setTMDBMatch(forPath: entry.path, tmdbID: tmdbID)
            } catch {
                lastError = "\(entry.candidate.title): \(error.localizedDescription)"
            }
        }
        progress = 1

        // Pull the freshly-tagged rows back into the AppModel so the main
        // library checkmark column updates immediately.
        appModel.reloadFromStore()
    }
}
