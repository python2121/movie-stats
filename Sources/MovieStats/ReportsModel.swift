import Foundation
import Observation

/// Library health + curation reports, computed on demand from the in-memory
/// movie list and the subtitle inventory. Each report is a flat list of
/// rows; the window renders whichever report is selected in its sidebar.
@MainActor
@Observable
final class ReportsModel {
    enum Kind: String, CaseIterable, Identifiable {
        case noEnglishSubs = "No English Subtitles"
        case upgradeCandidates = "Upgrade Candidates"
        case duplicateMatches = "Duplicate Matches"
        case vobsubOrphans = "VobSub Orphans"
        case unmatched = "Unmatched Movies"
        case spaceSavers = "Space Savers"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .noEnglishSubs:     return "captions.bubble"
            case .upgradeCandidates: return "arrow.up.circle"
            case .duplicateMatches:  return "doc.on.doc"
            case .vobsubOrphans:     return "doc.questionmark"
            case .unmatched:         return "questionmark.square.dashed"
            case .spaceSavers:       return "externaldrive.badge.minus"
            }
        }

        var explanation: String {
            switch self {
            case .noEnglishSubs:
                return "Movies with no English subtitles — neither an embedded track nor an external subtitle file. External files with no language code in their filename (e.g. \"Movie.srt\" instead of \"Movie.en.srt\") can't be identified and might be English; those are noted per row."
            case .upgradeCandidates:
                return "Well-regarded movies (IMDb ≥ 7.0) stuck in low-quality files: SD, 720p, or a starved 1080p encode under 4 Mbps. Prime re-download candidates."
            case .duplicateMatches:
                return "Two or more files matched to the same TMDB movie. Keep the best copy; the Rename window flags these as conflicts too."
            case .vobsubOrphans:
                return "VobSub halves missing their partner: an .idx without its .sub is dead weight; a .sub without an .idx might be a standalone MicroDVD subtitle, so check before deleting."
            case .unmatched:
                return "Movies with no TMDB match yet — no canonical title, ratings, or rename support until they're matched."
            case .spaceSavers:
                return "Poorly-rated movies (IMDb < 6.0) over 20 GB. Each one you delete buys real space back."
            }
        }
    }

    struct Row: Identifiable, Hashable {
        let path: String
        let title: String
        let detail: String
        let size: Int64?
        var id: String { path }
    }

    private(set) var rows: [Kind: [Row]] = [:]

    func refresh(movies: [MovieFile], store: MovieStore?) {
        let subtitles = (try? store?.allSubtitleFiles()) ?? []
        let subsByMovie = Dictionary(grouping: subtitles, by: { $0.moviePath ?? "" })

        rows[.noEnglishSubs] = noEnglishSubs(movies: movies, subsByMovie: subsByMovie)
        rows[.upgradeCandidates] = upgradeCandidates(movies: movies)
        rows[.duplicateMatches] = duplicateMatches(movies: movies)
        rows[.vobsubOrphans] = vobsubOrphans(subtitles: subtitles)
        rows[.unmatched] = unmatched(movies: movies)
        rows[.spaceSavers] = spaceSavers(movies: movies)
    }

    private func noEnglishSubs(
        movies: [MovieFile],
        subsByMovie: [String: [SubtitleFile]]
    ) -> [Row] {
        movies.compactMap { movie in
            guard movie.probedAt != nil else { return nil }
            let embeddedEnglish = movie.subtitleLanguages.contains { $0.lowercased().hasPrefix("en") }
            let external = subsByMovie[movie.path] ?? []
            let externalEnglish = external.contains { $0.language == "en" }
            guard !embeddedEnglish && !externalEnglish else { return nil }

            var have: [String] = []
            let embeddedLangs = Set(movie.subtitleLanguages.map { $0.lowercased() })
                .subtracting(["und", ""])
            if !embeddedLangs.isEmpty {
                have.append("embedded: \(embeddedLangs.sorted().joined(separator: ", "))")
            }
            let externalLangs = Set(external.compactMap(\.language))
            if !externalLangs.isEmpty {
                have.append("sidecar: \(externalLangs.sorted().joined(separator: ", "))")
            }
            let untagged = external.filter { $0.language == nil }.count
            if untagged > 0 {
                have.append("\(untagged) subtitle file\(untagged == 1 ? "" : "s") with no language tag")
            }
            return Row(
                path: movie.path,
                title: movie.displayTitle,
                detail: have.isEmpty ? "no subtitles at all" : have.joined(separator: " · "),
                size: movie.size
            )
        }
    }

    private func upgradeCandidates(movies: [MovieFile]) -> [Row] {
        movies.compactMap { movie in
            guard let rating = movie.imdbRating, rating >= 7.0 else { return nil }
            let lowQuality: String?
            switch movie.movieType {
            case MovieType.sd.rawValue:
                lowQuality = "SD"
            case MovieType.hdEncode.rawValue:
                lowQuality = "720p"
            case MovieType.fullHDEncode.rawValue:
                if let bitrate = movie.bitrate, bitrate < 4_000_000 {
                    lowQuality = String(format: "1080p @ %.1f Mbps", Double(bitrate) / 1_000_000)
                } else {
                    lowQuality = nil
                }
            default:
                lowQuality = nil
            }
            guard let quality = lowQuality else { return nil }
            return Row(
                path: movie.path,
                title: movie.displayTitle,
                detail: String(format: "IMDb %.1f · %@", rating, quality),
                size: movie.size
            )
        }
        .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    private func duplicateMatches(movies: [MovieFile]) -> [Row] {
        let grouped = Dictionary(grouping: movies.filter { $0.tmdbId != nil }, by: { $0.tmdbId! })
        return grouped.values
            .filter { $0.count > 1 }
            .flatMap { copies -> [Row] in
                let sorted = copies.sorted { $0.size > $1.size }
                return sorted.enumerated().map { idx, movie in
                    Row(
                        path: movie.path,
                        title: movie.displayTitle,
                        detail: idx == 0
                            ? "largest of \(sorted.count) copies"
                            : "smaller copy \(idx + 1) of \(sorted.count)",
                        size: movie.size
                    )
                }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func vobsubOrphans(subtitles: [SubtitleFile]) -> [Row] {
        let vobsubs = subtitles.filter { $0.format == "idx" || $0.format == "sub" }
        let stems = Dictionary(grouping: vobsubs) { sub in
            (sub.path as NSString).deletingPathExtension
        }
        return stems.values
            .filter { $0.count == 1 }
            .map { group in
                let sub = group[0]
                let detail = sub.format == "idx"
                    ? "missing its .sub partner — dead weight"
                    : "no .idx partner — might be a standalone MicroDVD subtitle"
                return Row(path: sub.path, title: sub.filename, detail: detail, size: sub.size)
            }
            .sorted { $0.path < $1.path }
    }

    private func unmatched(movies: [MovieFile]) -> [Row] {
        movies
            .filter { $0.tmdbId == nil }
            .map { Row(path: $0.path, title: $0.displayTitle, detail: $0.filename, size: $0.size) }
    }

    private func spaceSavers(movies: [MovieFile]) -> [Row] {
        movies
            .compactMap { movie -> (MovieFile, Double)? in
                guard movie.size >= AppModel.largeFileThreshold,
                      let rating = movie.imdbRating, rating < 6.0
                else { return nil }
                return (movie, rating)
            }
            .sorted { $0.0.size > $1.0.size }
            .map { movie, rating in
                Row(
                    path: movie.path,
                    title: movie.displayTitle,
                    detail: String(format: "IMDb %.1f", rating),
                    size: movie.size
                )
            }
    }
}
