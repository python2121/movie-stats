import Foundation

/// One pending extras relocation the RenameModel should fold into its
/// plan. The import wizard's Multi-Videos step builds these from the
/// user's Extra checkboxes; the standalone library scope returns none.
struct ExtraRenameRequest: Equatable {
    /// The extra's marking-time path. Same key used by
    /// `session.movies` for that file, so the rename model can locate
    /// + update it just like a regular movie row.
    let markedPath: String
    /// Basename to use as the final filename inside `Other/`. Not
    /// canonicalized today — the bonus-content folder name is the
    /// classifier in Plex/Jellyfin; arbitrary names are accepted.
    let filename: String
    /// File size, captured at marking time so we don't re-stat just
    /// to write the post-move DB row.
    let size: Int64
    /// TMDB id of the parent movie. Used to look up the parent's
    /// rename row at plan time so the extra's target path can land
    /// inside the parent's *post-rename* wrapper.
    let parentTMDBId: Int
    /// Path relative to the parent movie's containing folder at
    /// marking time. Carries any intermediate subfolders (e.g.
    /// `Extras-Grym/Doc.mkv`) so move-time discovery resolves the
    /// file even if the parent's wrapper has since been renamed.
    let relativeToParentDir: String
}

/// What RenameModel reports back to the scope after successfully
/// relocating an extra. The scope keeps this around so a later step
/// (Move to Library) can finalize the DB insert under the file's
/// post-move library path.
struct ExtraRelocationOutcome: Equatable {
    /// Source-side path right after the relocation move — sits inside
    /// the parent's wrapper's `Other/` folder, ready to ride along
    /// when the wrapper itself moves to the library.
    let sourceAfterMove: String
    /// Parent movie's current source-side path, used as the second
    /// half of the eventual library-path swap.
    let parentSourcePath: String
    let parentTMDBId: Int
    let filename: String
    let size: Int64
}

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
    /// Extras the rename step should plan + execute as first-class
    /// rows. Standalone library scope returns empty; ImportSession
    /// derives one entry per Extra checkbox from the Multi-Videos
    /// step.
    var pendingExtras: [ExtraRenameRequest] { get }
    /// Reports back when an extras row's relocation succeeded so the
    /// scope can finalize bookkeeping (e.g. ImportSession needs the
    /// outcome at Move-to-Library time to write the `extras` table
    /// row under the file's final library path). Standalone scopes
    /// treat as no-op.
    func recordExtraRelocation(_ outcome: ExtraRelocationOutcome)
}

extension MovieScope {
    var pendingExtras: [ExtraRenameRequest] { [] }
    func recordExtraRelocation(_ outcome: ExtraRelocationOutcome) {}
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
