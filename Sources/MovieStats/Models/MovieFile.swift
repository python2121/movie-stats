import Foundation

/// A single movie file discovered during a directory scan.
///
/// The basic fields (`path`, `filename`, `size`) are filled in by the file
/// scanner; everything below `dateScanned` is filled in by `MediaProbe` after
/// `ffprobe` reads the file's headers, and stays nil/zero until that probe
/// completes.
struct MovieFile: Identifiable, Hashable, Sendable {
    /// Full filesystem path; also the primary key in the database.
    var path: String
    /// Just the file name, e.g. "The Matrix (1999).mkv".
    var filename: String
    /// File size in bytes.
    var size: Int64
    /// When this file was last seen by a scan.
    var dateScanned: Date

    /// Title extracted from the filename by `TitleParser` (e.g. "The Matrix").
    /// Empty only for very old DB rows that haven't been touched since the
    /// title column was added — UI falls back to `filename` in that case.
    var parsedTitle: String = ""
    /// Release year if `TitleParser` found one in the filename.
    var parsedYear: Int?

    /// TMDB id this file is matched to, or nil if it hasn't been matched yet.
    /// When non-nil, the full TMDB detail lives in the `tmdb_movies` table —
    /// look it up via `MovieStore.tmdbDetail(forID:)`.
    var tmdbId: Int?

    /// When this path first appeared in a scan — unlike `dateScanned`, it
    /// survives rescans, so it means "added to the library".
    var firstSeenAt: Date?
    /// When the user marked this movie watched, nil = unwatched.
    var watchedAt: Date?
    /// User's own 1–5 star rating, independent of IMDb/TMDB scores.
    var personalRating: Int?

    /// Genre names from the joined TMDB record (decoded from genres_json).
    var genres: [String] = []
    /// TMDB runtime in minutes.
    var runtimeMinutes: Int?
    /// TMDB collection ("franchise") this movie belongs to, when matched.
    var collectionID: Int?
    var collectionName: String?
    /// TMDB poster path (e.g. "/abc.jpg") — lets the poster wall fetch
    /// artwork on demand for matches confirmed before poster caching existed.
    var posterPath: String?

    /// IMDb tconst pulled from the joined TMDB record. Nil for unmatched
    /// movies or TMDB records that don't carry an IMDb id.
    var imdbId: String?
    /// IMDb's average rating (0–10) when the bulk dataset has been imported
    /// and this movie has a tconst that's in it. Nil otherwise.
    var imdbRating: Double?
    /// Number of IMDb votes that produced `imdbRating`. Used in tooltips.
    var imdbVotes: Int?

    /// Canonical TMDB title pulled from the joined `tmdb_movies` row.
    /// Nil for unmatched movies; takes precedence over `parsedTitle` in
    /// `displayTitle` when present.
    var tmdbTitle: String?
    /// TMDB's preferred year (earliest premiere/theatrical across all
    /// countries), derived from `release_dates` with `release_date` as
    /// fallback. Used as a fallback when `confirmedYear` isn't set.
    var tmdbYear: Int?
    /// Locked-in year from the matcher — exactly what the user saw and
    /// signed off on at confirm time. Wins over `tmdbYear` because TMDB's
    /// search and details endpoints don't always agree on `release_date`
    /// (the Perfect Blue / Miracle Mile festival-year case).
    var confirmedYear: Int?

    /// Optional user-typed edition label (e.g. "4K77 v1.4",
    /// "Director's Cut", "Despecialized v2.7") captured by the matcher
    /// when picking a TMDB candidate. The renamer emits this as
    /// `{edition-<value>}` in the canonical filename so Plex / Jellyfin
    /// can surface multiple cuts of the same TMDB id as alternate
    /// versions under one library entry. Stored in
    /// `movies.custom_edition`.
    var customEdition: String?

    /// Disc / part number extracted from the filename's `cd<N>` /
    /// `disc<N>` / `disk<N>` / `pt<N>` / `part<N>` / `dvd<N>` token,
    /// when present. Drives the multi-part collapse in the library
    /// list (parts of one movie share a row, with a Play menu that
    /// labels each disc) and the `- pt<N>` suffix the renamer emits.
    /// nil for single-file movies (the common case). Stored in
    /// `movies.part_number`.
    var partNumber: Int?

    /// Year to use when rendering this movie everywhere outside of the
    /// matcher itself. Precedence: matcher's locked-in confirmation →
    /// TMDB's preferred-release year → filename-parsed year.
    var effectiveYear: Int? {
        confirmedYear ?? tmdbYear ?? parsedYear
    }

    /// Title-sort key that ignores leading English articles, so
    /// "The Matrix" files under M — matching Plex / Finder-adjacent
    /// media-library convention.
    var sortTitle: String {
        let title = displayTitle.lowercased()
        for article in ["the ", "a ", "an "] where title.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }

    /// `"Title (Year)"`. Prefers the canonical TMDB title + year when the
    /// movie has been matched, falling back to the filename-parsed title /
    /// year (and ultimately the raw filename) when it hasn't.
    var displayTitle: String {
        if let tmdbTitle, !tmdbTitle.isEmpty {
            if let year = confirmedYear ?? tmdbYear { return "\(tmdbTitle) (\(year))" }
            return tmdbTitle
        }
        if parsedTitle.isEmpty { return filename }
        if let year = parsedYear { return "\(parsedTitle) (\(year))" }
        return parsedTitle
    }

    // MARK: - Probed metadata (nil/0/false/[] until ffprobe runs)

    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var bitrate: Int?
    var videoCodec: String?
    var container: String?
    var pixFmt: String?
    var is10Bit: Bool = false
    /// "HDR10", "HLG", or nil. Stored alongside `hasDolbyVision` because a
    /// single file can be both HDR10 *and* DV.
    var hdrFormat: String?
    var hasDolbyVision: Bool = false
    var videoTracks: Int = 0
    var audioTracks: Int = 0
    var subtitleTracks: Int = 0
    /// Comma-friendly arrays — persisted in SQLite as joined strings. The
    /// `*Languages` arrays parallel `*Codecs` by index.
    var audioCodecs: [String] = []
    var audioChannels: [Int] = []
    var audioLanguages: [String] = []
    var subtitleCodecs: [String] = []
    var subtitleLanguages: [String] = []
    /// `MovieType.rawValue` — the derived library category. Nil while the row
    /// hasn't been probed yet.
    var movieType: String?
    /// Timestamp of the last successful probe. Nil rows are what `probeMissing`
    /// picks up to work through.
    var probedAt: Date?

    var id: String { path }
}
