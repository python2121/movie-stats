import Foundation

/// The minimum interface a "library context" needs to provide to the
/// matcher and rename models so they can operate against *some* set of
/// movies without caring whether that set lives in the persistent
/// library or in a transient import session.
///
/// `AppModel` is the live, DB-backed implementation that drives the
/// main library window. `ImportSession` is the in-memory implementation
/// that backs the import wizard: it doesn't write to the `movies` table
/// until the user clicks Move to Library, so its `setTMDBMatch` /
/// `updatePath` methods just patch an in-memory snapshot. Reads of the
/// shared `tmdb_movies` cache pass through `store` so both scopes share
/// TMDB metadata (it's path-independent).
@MainActor
protocol MovieScope: AnyObject {
    /// Snapshot of every file currently in scope.
    var movies: [MovieFile] { get }
    /// Filesystem directory the scope is rooted at — used by the rename
    /// model as the wrapper-folder boundary.
    var directoryPath: String { get }
    /// Shared store, used for reading + writing the global TMDB cache
    /// (`tmdb_movies`) and — for the live `AppModel` — also as the
    /// backing for `setTMDBMatch` and `updatePath`. For an import scope,
    /// the store is still surfaced so the cache write-through works.
    var store: MovieStore? { get }
    /// Refresh `movies` to reflect anything that changed via the store
    /// (e.g. the matcher just wrote new TMDB ids). For an import scope
    /// this is typically a no-op because mutations land in memory
    /// directly.
    func reloadFromStore()
    /// Record a TMDB match for the file at `path`. Live scope writes
    /// it through to the DB; import scope updates the in-memory entry.
    /// `customEdition` is an optional user-typed label like
    /// `"4K77 v1.4"` or `"Director's Cut"` that gets emitted by the
    /// renamer as `{edition-<value>}` in the canonical filename. nil /
    /// empty means no edition tag.
    func setTMDBMatch(forPath path: String, tmdbID: Int?, confirmedYear: Int?, customEdition: String?) throws
    /// Record that the file at `oldPath` has been renamed to `newPath`
    /// on disk. Live scope writes it through to the DB; import scope
    /// updates the in-memory entry so subsequent steps see the new path.
    func updatePath(oldPath: String, newPath: String, newFilename: String) throws
}

extension AppModel: MovieScope {
    func setTMDBMatch(
        forPath path: String,
        tmdbID: Int?,
        confirmedYear: Int?,
        customEdition: String?
    ) throws {
        try store?.setTMDBMatch(
            forPath: path,
            tmdbID: tmdbID,
            confirmedYear: confirmedYear,
            customEdition: customEdition
        )
    }

    func updatePath(oldPath: String, newPath: String, newFilename: String) throws {
        try store?.updatePath(oldPath: oldPath, newPath: newPath, newFilename: newFilename)
    }
}
