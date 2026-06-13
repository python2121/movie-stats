import Foundation

/// Tiny string-similarity helper used by the matcher to recognize
/// near-identical titles (e.g. "Mr & Mrs Smith" vs "Mr. and Mrs. Smith")
/// where TMDB and the filename agree on the film but punctuation drifts.
/// Returns a normalized Levenshtein ratio in [0, 1].
private enum TitleSimilarity {
    /// Strips punctuation, collapses whitespace, lowercases. Leaves the bytes
    /// the actual title carries — no aggressive stemming or stop-word removal.
    /// `&` is folded to `and` before stripping so "Mr. & Mrs. Smith" and
    /// "Mr. and Mrs. Smith" normalize identically.
    static func normalize(_ s: String) -> String {
        let lower = s
            .replacingOccurrences(of: "&", with: " and ")
            .lowercased()
        var scalars = String.UnicodeScalarView()
        var prevWasSpace = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                prevWasSpace = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" || scalar == "_" {
                if !prevWasSpace, !scalars.isEmpty {
                    scalars.append(" ")
                    prevWasSpace = true
                }
            }
            // Other punctuation (periods, commas, colons, …) is dropped.
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Normalized similarity. 1.0 = identical after normalization.
    static func ratio(_ a: String, _ b: String) -> Double {
        let lhs = normalize(a)
        let rhs = normalize(b)
        if lhs == rhs { return 1.0 }
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let n = lhsChars.count
        let m = rhsChars.count
        if n == 0 || m == 0 { return 0.0 }

        var prev = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(
                    curr[j - 1] + 1,
                    prev[j] + 1,
                    prev[j - 1] + cost
                )
            }
            swap(&prev, &curr)
        }
        return 1.0 - Double(prev[m]) / Double(Swift.max(n, m))
    }
}

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
        /// Year to display for the candidate when it differs from
        /// `candidate.year`. Populated by scan when TMDB's primary
        /// release year disagrees with the filename year — the scanner
        /// then fetches `/movie/{id}` with `append_to_response=release_dates`
        /// and stores the US-theatrical year here. Fixes the off-by-one
        /// shown for foreign films whose origin-country premiere predates
        /// their US wide release.
        var preferredYear: String?
        /// Optional user-typed edition label (e.g. "4K77 v1.4",
        /// "Director's Cut") captured from the manual-pick sheet.
        /// Flows into the canonical filename as `{edition-<value>}` at
        /// rename time, so multiple cuts of the same TMDB id can
        /// coexist under one wrapper folder. nil for the typical row.
        var customEdition: String?

        var id: String { path }

        /// The candidate's title with the most user-meaningful year applied —
        /// `preferredYear` when present, otherwise TMDB's primary
        /// `release_date` year.
        var candidateDisplayTitle: String {
            guard let candidate else { return "" }
            let year = preferredYear ?? candidate.year
            if let year { return "\(candidate.title) (\(year))" }
            return candidate.title
        }

        /// Confidence threshold (per-character normalized Levenshtein) above
        /// which a same-year candidate is treated as a confident match.
        static let fuzzyTitleThreshold: Double = 0.80

        /// True when the candidate is a confident match for this file:
        /// either the "Title (Year)" strings agree exactly, or the years
        /// agree and the titles are at least `fuzzyTitleThreshold` similar.
        /// Drives green text and the initial auto-include state.
        var isExactMatch: Bool {
            guard let candidate else { return false }
            if candidateDisplayTitle == displayTitle { return true }

            // Same-year + close-enough title fuzzy path. Catches punctuation
            // drift like "Mr & Mrs" vs "Mr. and Mrs.", "WALL-E" vs "WALL·E",
            // "Spider-Man: Homecoming" vs "Spider Man Homecoming", etc.
            guard let parsedYear,
                  let candYearStr = preferredYear ?? candidate.year,
                  let candYear = Int(candYearStr),
                  parsedYear == candYear else { return false }
            return TitleSimilarity.ratio(parsedTitle, candidate.title) >= Self.fuzzyTitleThreshold
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

    private let scope: any MovieScope
    private var scanTask: Task<Void, Never>?
    /// When true, every candidate change writes the basic `(tmdbId,
    /// confirmedYear, customEdition)` through to `scope` immediately
    /// — no batched-Confirm checkpoint. The import wizard turns this
    /// on so a user who picks a candidate then clicks Next (without
    /// matcher-Confirm) doesn't drop the match. Standalone library
    /// matcher leaves it off — Confirm is the user's atomic
    /// checkpoint there. `confirm()` still runs in either mode and
    /// upgrades the row with the cached TMDB detail's authoritative
    /// year + caches the poster.
    private let autoCommitOnPick: Bool

    init(scope: any MovieScope, autoCommitOnPick: Bool = false) {
        self.scope = scope
        self.autoCommitOnPick = autoCommitOnPick
    }

    /// Writes the row's current candidate/edition through to the
    /// scope when auto-commit is on. Bridges the gap between a
    /// pending pick and the explicit-Confirm commit so downstream
    /// surfaces (import wizard's Replace + Extra eligibility) see
    /// the match without an intermediate user action.
    private func commitToScopeIfAutoMode(rowID: Row.ID) {
        guard autoCommitOnPick,
              let idx = rows.firstIndex(where: { $0.id == rowID })
        else { return }
        let row = rows[idx]
        if let candidate = row.candidate {
            // Year sourced from the candidate's search-endpoint year;
            // `confirm()` later refines this with the
            // release_dates-derived preferredReleaseDate.
            let year = candidate.year.flatMap(Int.init)
            try? scope.setTMDBMatch(
                forPath: row.path,
                tmdbID: candidate.id,
                confirmedYear: year,
                customEdition: row.customEdition
            )
        } else {
            // Cleared candidate — remove the match from the scope so
            // a stale tmdbId can't survive on session.movies.
            try? scope.setTMDBMatch(
                forPath: row.path,
                tmdbID: nil,
                confirmedYear: nil,
                customEdition: nil
            )
        }
    }

    /// Rebuilds `rows` from the scope's current unmatched movies. Call
    /// each time the window is opened so we pick up newly-scanned files.
    func reload() {
        rows = scope.movies
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

            // Fast path: if the source path already embeds a `{tmdb-N}`
            // tag (from a prior rename, the import wizard, or any
            // external tool that follows the convention), look up the
            // movie by ID directly. That's unambiguous — bypasses the
            // fuzzy title search entirely, which sidesteps both the
            // diacritic quirk on TMDB's search endpoint and any
            // year/title-parsing flakiness.
            if let tmdbID = TMDBService.tmdbID(fromPath: row.path),
               let detail = try? await TMDBService.details(forID: tmdbID) {
                let candidate = TMDBMovie(
                    id: detail.id,
                    title: detail.title,
                    originalTitle: detail.originalTitle,
                    releaseDate: detail.releaseDate,
                    overview: detail.overview,
                    voteAverage: detail.voteAverage,
                    voteCount: detail.voteCount,
                    posterPath: detail.posterPath
                )
                rows[index].candidate = candidate
                rows[index].preferredYear = detail.year
                rows[index].status = .matched
                rows[index].failureReason = nil
                // An embedded TMDB id is an explicit user (or tool)
                // signal — treat as auto-include, no review needed.
                rows[index].included = true
                commitToScopeIfAutoMode(rowID: rows[index].id)
                continue
            }

            let queryTitle = row.parsedTitle.isEmpty
                ? row.displayTitle
                : row.parsedTitle
            do {
                let results = try await TMDBService.searchMovies(
                    title: queryTitle,
                    year: row.parsedYear
                )
                if let first = results.first {
                    // If the parsed filename year disagrees with TMDB's
                    // primary year on the top hit, fetch details to get the
                    // US-theatrical year — fixes the off-by-one for foreign
                    // films. Only one extra HTTP call per mismatched row;
                    // matching-year rows pay nothing.
                    var preferredYear: String?
                    if let parsedYear = row.parsedYear,
                       let searchYearStr = first.year,
                       let searchYear = Int(searchYearStr),
                       parsedYear != searchYear,
                       let detail = try? await TMDBService.details(forID: first.id) {
                        preferredYear = detail.year
                    }

                    rows[index].candidate = first
                    rows[index].preferredYear = preferredYear
                    rows[index].status = .matched
                    rows[index].failureReason = nil
                    // Only auto-include exact matches; everything else
                    // waits for explicit user review.
                    rows[index].included = rows[index].isExactMatch
                    // Auto-commit fires only when the row was
                    // auto-included (exact match) — fuzzy matches
                    // shouldn't slip a Match through without the
                    // user's eye on them.
                    if rows[index].included {
                        commitToScopeIfAutoMode(rowID: rows[index].id)
                    }
                } else {
                    rows[index].candidate = nil
                    rows[index].preferredYear = nil
                    rows[index].status = .failed
                    rows[index].failureReason = "No TMDB result"
                    rows[index].included = false
                }
            } catch {
                rows[index].candidate = nil
                rows[index].preferredYear = nil
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
    /// The preferred-year override is dropped — it belonged to the previous
    /// candidate. `customEdition` is the optional edition label the user
    /// typed alongside the search; nil means "no edition tag, treat as
    /// the canonical version."
    func setCandidate(_ candidate: TMDBMovie, customEdition: String?, for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].candidate = candidate
        rows[idx].preferredYear = nil
        rows[idx].status = .matched
        rows[idx].failureReason = nil
        rows[idx].included = true
        let trimmed = customEdition?.trimmingCharacters(in: .whitespacesAndNewlines)
        rows[idx].customEdition = (trimmed?.isEmpty == false) ? trimmed : nil
        commitToScopeIfAutoMode(rowID: rowID)
    }

    /// Removes the candidate from a row (e.g. user clears it before
    /// re-running the manual search).
    func clearCandidate(for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].candidate = nil
        rows[idx].preferredYear = nil
        rows[idx].status = .pending
        rows[idx].failureReason = nil
        rows[idx].included = false
        commitToScopeIfAutoMode(rowID: rowID)
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
        var confirmedPaths: Set<String> = []
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
                } else if let existing = try? scope.store?.tmdbDetail(forID: tmdbID) {
                    // Already have this TMDB row from a previous confirm.
                    detail = existing
                    detailCache[tmdbID] = existing
                } else {
                    detail = try await TMDBService.details(forID: tmdbID)
                    try scope.store?.upsertTMDBDetail(detail)
                    detailCache[tmdbID] = detail
                }

                // Cache poster art on disk (no-op if already there).
                await PosterCache.downloadIfNeeded(
                    tmdbID: tmdbID,
                    posterPath: detail.posterPath
                )

                // Lock in the exact year the matcher showed for this row.
                // `candidateDisplayTitle` uses `preferredYear ?? candidate.year`
                // — that's what the user saw next to the title and agreed
                // to when checking the box. Persisting it sidesteps the
                // search-endpoint-vs-details-endpoint year drift in TMDB.
                let row = rows.first(where: { $0.path == entry.path })
                let yearString = row?.preferredYear ?? entry.candidate.year
                let confirmedYear = yearString.flatMap(Int.init)
                try scope.setTMDBMatch(
                    forPath: entry.path,
                    tmdbID: tmdbID,
                    confirmedYear: confirmedYear,
                    customEdition: row?.customEdition
                )
                confirmedPaths.insert(entry.path)
            } catch {
                lastError = "\(entry.candidate.title): \(error.localizedDescription)"
            }
        }
        progress = 1

        // Drop just-confirmed rows from the working list so the matcher only
        // shows what's still unmatched. Rows that failed to write stay put
        // with their candidate intact so the user can retry without
        // re-picking.
        if !confirmedPaths.isEmpty {
            rows.removeAll { confirmedPaths.contains($0.path) }
        }
        currentIndex = nil

        // Pull the freshly-tagged rows back into the AppModel so the main
        // library checkmark column updates immediately.
        scope.reloadFromStore()
    }
}
