import Foundation

/// Background detection for Smart Import. Walks a watch directory and reports
/// which videos confidently match a TMDB entry, using the *same* confidence
/// rule the interactive matcher applies (`MatcherModel.Row.isConfidentMatch`).
///
/// Detection only — no DB writes, no poster caching, no deletes, no renames.
/// The full match (detail fetch, poster cache, `confirmedYear`) happens later
/// in `SmartImportModel.prepare` when the user opens the window. This pass
/// exists solely to decide whether the toolbar button lights up blue, so it
/// stays cheap: one search call per video, year sourced from the search
/// endpoint (no per-row details fetch).
enum SmartImportScanner {
    /// Returns the paths of every video beneath `watchDirectory` that
    /// confidently auto-matches TMDB. Empty when no API key is configured or
    /// the directory is unset/empty. Safe to call off the main actor.
    static func confidentMatches(in watchDirectory: String) async -> [String] {
        guard !watchDirectory.isEmpty, TMDBService.apiKey != nil else { return [] }

        let url = URL(fileURLWithPath: watchDirectory)
        let files = await Task.detached(priority: .background) {
            DirectoryScanner.scan(directory: url)
        }.value

        var matched: [String] = []
        for file in files {
            // An embedded `{tmdb-N}` tag is an unambiguous match — no search
            // needed (mirrors the matcher's fast path).
            if TMDBService.tmdbID(fromPath: file.path) != nil {
                matched.append(file.path)
                continue
            }

            let parsed = TitleParser.parse(filename: file.filename)
            let query = parsed.title.isEmpty ? file.filename : parsed.title
            guard let results = try? await TMDBService.searchMovies(title: query, year: parsed.year),
                  let first = results.first
            else { continue }

            if MatcherModel.Row.isConfidentMatch(
                parsedTitle: parsed.title,
                parsedYear: parsed.year,
                fileDisplayTitle: parsed.displayName,
                candidateTitle: first.title,
                candidateYear: first.year
            ) {
                matched.append(file.path)
            }
        }
        return matched
    }
}
