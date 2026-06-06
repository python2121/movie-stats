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

    /// `"Title (Year)"` when both are available; otherwise just the title.
    /// Falls back to the filename if parsing produced nothing.
    var displayTitle: String {
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
