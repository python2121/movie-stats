import Foundation

/// One auxiliary video file (a deleted scene, featurette, behind-the-
/// scenes clip, etc.) the user classified as an "Extra" during the
/// import wizard's Multiple Videos step. Persisted in the `extras`
/// table so future sessions can surface the bonus content alongside
/// the main movie.
///
/// Both Plex and Jellyfin recognize an `Other/` subfolder inside a
/// movie's wrapper as the catch-all extras bucket; this model
/// captures whatever the renamer parked into that folder.
struct ExtraFile: Identifiable, Hashable, Sendable {
    /// Final on-disk path inside the library, e.g.
    /// `<library>/Movie (Year) {tmdb-N}/Other/Deleted Scene 01.mkv`.
    let path: String
    /// The parent movie's library path, when we could identify it
    /// (the parent had a confirmed TMDB match at import time).
    let parentMoviePath: String?
    /// The parent movie's TMDB id. Kept on the row even when
    /// `parentMoviePath` is nil so a future rescan can re-attribute.
    let parentTMDBId: Int?
    /// The Plex/Jellyfin extras-folder name the file lives in. Always
    /// `"Other"` for now — future categorization (Behind The Scenes,
    /// Trailers, etc.) would reuse this column.
    let category: String
    let filename: String
    let size: Int64
    /// First-time-recorded timestamp. Not touched by future updates.
    let addedAt: TimeInterval

    var id: String { path }
}
