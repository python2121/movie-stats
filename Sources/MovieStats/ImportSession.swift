import Foundation
import Observation

/// Drives the import wizard: a `/complete`-style source directory the
/// user is preparing for inclusion in the main `/movies` library. The
/// session walks the user through TMDB matching → image / text / multi-
/// video / empty-folder cleanup → renaming, all scoped to the source
/// directory. None of the matched files land in the persistent `movies`
/// table until the user clicks "Move to Library" at the end — until
/// then, this object is an authoritative *in-memory* mirror of the
/// source's scanned movies plus the user's TMDB choices.
///
/// Conforms to `MovieScope` so the existing `MatcherModel` and
/// `RenameModel` can drive their UIs against the import session without
/// caring that the data isn't in the DB yet.
@MainActor
@Observable
final class ImportSession: MovieScope {
    /// Reference to the live app — used for the shared TMDB cache, the
    /// library destination, and the final DB-refresh hook after Move to
    /// Library completes.
    private let appModel: AppModel

    /// Absolute path of the directory the user picked. Empty until the
    /// user picks one in step 0.
    private(set) var sourceDirectory: String = ""

    /// In-memory snapshot of video files scanned from `sourceDirectory`.
    /// Mutates as the matcher writes TMDB ids and the rename step
    /// updates paths.
    private(set) var movies: [MovieFile] = []

    /// Cached TMDB matches for files in this import. Keyed by *current*
    /// file path because the rename step rewrites paths and we need to
    /// re-key these alongside. The `confirmedYear` mirrors what the
    /// matcher locked in.
    private(set) var tmdbMatches: [String: (tmdbID: Int, confirmedYear: Int?, customEdition: String?)] = [:]

    /// Where we are in the wizard.
    var currentStep: Step = .pickDirectory

    /// User-toggled at the ready step: if true, Move to Library deletes
    /// the source directory after a successful move *only* when it's
    /// left fully empty (ignoring hidden cruft like `.DS_Store`). The
    /// canonical use is the single-movie case where the source folder
    /// becomes an empty husk after its lone wrapper has been moved out.
    /// Defaults to off because the deletion is permanent — files are
    /// not sent to the Trash on the network volumes this app targets.
    var autoPruneSource: Bool = false

    /// True while a long-running operation (scan, move) is in flight.
    private(set) var isBusy: Bool = false
    private(set) var busyMessage: String = ""

    /// Last error surfaced from any step. Cleared whenever we advance.
    var lastError: String?

    /// True iff the source has been scanned and the user can proceed.
    var hasScanned: Bool { !sourceDirectory.isEmpty && !movies.isEmpty }

    /// True iff every scanned movie has a confirmed TMDB match — only
    /// then is the rename step useful. (The matcher step is "complete"
    /// when this is true, but the user can also skip ahead manually.)
    var allMatched: Bool {
        !movies.isEmpty && movies.allSatisfy { $0.tmdbId != nil }
    }

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    // MARK: - MovieScope

    /// The rename model uses this as the canonical wrapper-folder
    /// boundary when walking source files. For an import scope the
    /// source directory plays exactly that role.
    var directoryPath: String { sourceDirectory }

    /// We piggy-back on the live app's store for shared TMDB / IMDb
    /// caches and for reading existing TMDB details. Writes to the
    /// path-keyed `movies` table from `MatcherModel` / `RenameModel`
    /// land harmlessly (UPDATE-no-op) because the import files aren't
    /// in that table — we capture them in memory via the methods
    /// below instead.
    var store: MovieStore? { appModel.store }

    func reloadFromStore() {
        // Intentionally a no-op. The in-memory `movies` array is
        // authoritative for this scope; `setTMDBMatch` and `updatePath`
        // already patched the relevant rows directly.
    }

    func setTMDBMatch(
        forPath path: String,
        tmdbID: Int?,
        confirmedYear: Int?,
        customEdition: String?
    ) throws {
        guard let idx = movies.firstIndex(where: { $0.path == path }) else { return }
        // Normalize empty / whitespace-only editions to nil so a typed-
        // then-cleared input doesn't leave an empty string lurking and
        // later render as `{edition-}`.
        let normalizedEdition: String? = customEdition
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        movies[idx].tmdbId = tmdbID
        movies[idx].confirmedYear = confirmedYear
        movies[idx].customEdition = normalizedEdition
        // Pull the canonical TMDB title/year forward so the in-memory
        // movie's `displayTitle` matches what the matcher locked in.
        // The detail is in the shared TMDB cache by the time the
        // matcher reaches `setTMDBMatch`.
        if let tmdbID, let detail = try? store?.tmdbDetail(forID: tmdbID) {
            movies[idx].tmdbTitle = detail.title
            movies[idx].tmdbYear = detail.year.flatMap(Int.init)
            movies[idx].imdbId = detail.imdbID
        }
        if let tmdbID {
            tmdbMatches[path] = (tmdbID, confirmedYear, normalizedEdition)
        } else {
            tmdbMatches.removeValue(forKey: path)
        }
    }

    func updatePath(oldPath: String, newPath: String, newFilename: String) throws {
        guard let idx = movies.firstIndex(where: { $0.path == oldPath }) else { return }
        movies[idx].path = newPath
        movies[idx].filename = newFilename
        // Re-key the TMDB match cache to the new path so downstream
        // steps (Move to Library) can still look it up.
        if let entry = tmdbMatches.removeValue(forKey: oldPath) {
            tmdbMatches[newPath] = entry
        }
        // Re-key any Replace mark for the same reason — without this,
        // `pendingReplacements` (which checks the row's *current*
        // session.movies path against `replaceMarkedPaths`) silently
        // returns empty after Rename runs, the library copy survives
        // into Move-to-Library, and the move loop then fails with
        // "destination already exists" because the canonical wrapper
        // is still occupied.
        if replaceMarkedPaths.remove(oldPath) != nil {
            replaceMarkedPaths.insert(newPath)
        }
    }

    // MARK: - Step 0: pick + scan

    /// Replaces the current source directory and scans it for video
    /// files. Clears any prior import state. Safe to call again to
    /// switch to a different source.
    func setSourceDirectory(_ path: String) async {
        sourceDirectory = path
        movies = []
        tmdbMatches.removeAll()
        replaceMarkedPaths.removeAll()
        extrasMarks.removeAll()
        recordedExtraRelocations.removeAll()
        currentStep = .pickDirectory
        lastError = nil
        await rescan()
    }

    /// Clears every piece of in-flight import state and returns the
    /// wizard to its first step (Pick Source). Bound to the wizard's
    /// Cancel Import button + Escape key — the user stays inside the
    /// window and can start a fresh import without closing and
    /// reopening it. No-op while an async operation is in flight so
    /// we can't yank state out from under it.
    func resetToStart() {
        guard !isBusy else { return }
        sourceDirectory = ""
        movies = []
        tmdbMatches.removeAll()
        replaceMarkedPaths.removeAll()
        extrasMarks.removeAll()
        recordedExtraRelocations.removeAll()
        lastError = nil
        busyMessage = ""
        currentStep = .pickDirectory
    }

    /// Walks the source directory for video files, builds the in-memory
    /// snapshot. Idempotent. Advances `currentStep` to `match` on
    /// success when nothing is matched yet, or just refreshes state
    /// when re-run from a later step.
    func rescan() async {
        guard !sourceDirectory.isEmpty, !isBusy else { return }
        isBusy = true
        busyMessage = "Scanning…"
        defer {
            isBusy = false
            busyMessage = ""
        }
        let url = URL(fileURLWithPath: sourceDirectory)
        let scanned = await Task.detached(priority: .userInitiated) {
            DirectoryScanner.scan(directory: url)
        }.value
        let now = Date()
        movies = scanned.map { file in
            let parsed = TitleParser.parse(filename: file.filename)
            return MovieFile(
                path: file.path,
                filename: file.filename,
                size: file.size,
                dateScanned: now,
                parsedTitle: parsed.title,
                parsedYear: parsed.year
            )
        }
        if currentStep == .pickDirectory, !movies.isEmpty {
            currentStep = .match
        }
    }

    // MARK: - Step navigation

    func advance() {
        guard let next = currentStep.next else { return }
        lastError = nil
        currentStep = next
    }

    func retreat() {
        guard let prev = currentStep.previous else { return }
        lastError = nil
        currentStep = prev
    }

    func jump(to step: Step) {
        guard hasScanned || step == .pickDirectory else { return }
        lastError = nil
        currentStep = step
    }

    // MARK: - Duplicate detection (imported movie already in the library)

    struct DuplicateConflict: Identifiable {
        let imported: MovieFile
        /// Library copies that share the imported file's (tmdbId,
        /// customEdition) slot — same TMDB id AND same edition label
        /// (nil / empty / whitespace all treated as "no edition"). A
        /// different edition under the same TMDB id is *not* a
        /// conflict; it's an alternate version Plex / Jellyfin would
        /// keep alongside.
        let existing: [MovieFile]
        var id: String { imported.path }
    }

    /// Normalizes a custom-edition label to a slot key. Whitespace and
    /// case are folded so two visually-identical labels match even if
    /// one was typed with a trailing space.
    private static func slotEdition(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Imported movies whose `(tmdbId, customEdition)` slot already
    /// exists in the live library. Recomputed on demand so it stays
    /// current as matches are confirmed, editions are typed, or the
    /// library changes.
    var duplicateConflicts: [DuplicateConflict] {
        // Group library by slot key so we can look each import up in
        // O(1). Edition is normalized to the same canonical form on
        // both sides so e.g. "Director's Cut " (with a trailing space)
        // matches "Director's Cut".
        var bySlot: [String: [MovieFile]] = [:]
        for libraryMovie in appModel.movies {
            guard let id = libraryMovie.tmdbId else { continue }
            let key = "\(id)|\(Self.slotEdition(libraryMovie.customEdition))"
            bySlot[key, default: []].append(libraryMovie)
        }
        return movies.compactMap { movie in
            guard let id = movie.tmdbId else { return nil }
            let key = "\(id)|\(Self.slotEdition(movie.customEdition))"
            guard let copies = bySlot[key], !copies.isEmpty else { return nil }
            return DuplicateConflict(imported: movie, existing: copies)
        }
    }

    // MARK: - Per-row Replace marks

    /// Import source paths the user has explicitly checked "Replace" on
    /// in the Match step. At Move-to-Library time these drive
    /// `replaceExistingCopies` — the library copies in each marked
    /// row's slot get permanently deleted before the new import moves
    /// in. The Match-step Next button shows a confirmation dialog when
    /// this set is non-empty so the user can't slip past unprompted.
    private(set) var replaceMarkedPaths: Set<String> = []

    /// Toggles a Replace mark for one imported file. Used by the
    /// Matcher's Replace-column checkbox.
    func setReplace(_ replace: Bool, forPath path: String) {
        if replace {
            replaceMarkedPaths.insert(path)
        } else {
            replaceMarkedPaths.remove(path)
        }
    }

    /// Clears any Replace marks whose import row no longer resolves to
    /// a real library duplicate — e.g. the user marked Replace, then
    /// re-opened the search sheet and picked a *different* TMDB
    /// candidate. Called from the Match-step Next handler so the
    /// confirmation dialog only ever counts live deletions.
    func pruneStaleReplaceMarks() {
        let liveDuplicatePaths = Set(duplicateConflicts.map { $0.imported.path })
        replaceMarkedPaths.formIntersection(liveDuplicatePaths)
    }

    /// Subset of `duplicateConflicts` whose import row the user has
    /// actually checked Replace on. The Match-step confirmation
    /// dialog itemizes these; Move-to-Library deletes from this list
    /// and ignores any unmarked conflicts.
    var pendingReplacements: [DuplicateConflict] {
        let marks = replaceMarkedPaths
        return duplicateConflicts.filter { marks.contains($0.imported.path) }
    }

    /// Performs the queued replacements — deletes each library copy in
    /// `pendingReplacements` (video + sidecars + wrapper when
    /// exclusive). Permanent deletes per the app's no-Trash design.
    ///
    /// Internal-only and called from exactly one place:
    /// `moveToLibrary`, after every other wizard step has succeeded.
    /// Keeping this method `private` is load-bearing — wiring it to
    /// a button or to the Match-step dialog would make destructive
    /// work fire before the user reaches the final step, which is
    /// the whole point of deferring deletion to Move to Library.
    private func performReplacements() async {
        let targets = pendingReplacements.flatMap { $0.existing }
        let failures = await appModel.deleteLibraryCopies(targets)
        if !failures.isEmpty {
            lastError = "Couldn't remove some existing copies:\n"
                + failures.joined(separator: "\n")
        }
    }

    // MARK: - Extras marks (Multiple Videos step)

    /// One entry in `extrasMarks`. Captures enough to relocate the file
    /// at Move-to-Library time without depending on a stable path —
    /// the rename step may have renamed the parent folder, or
    /// (in createFolderAndMove cases) moved the main into a new
    /// wrapper while leaving the extra where it was.
    struct ExtraMark: Hashable {
        /// File basename. Becomes the final filename inside `Other/`.
        var filename: String
        /// Total file size at marking time. Used for the DB record
        /// after the move completes (cheaper than re-statting).
        var size: Int64
        /// TMDB id of the parent movie. The parent's TMDB id
        /// survives the rename step where path strings do not.
        var parentTMDBId: Int
        /// The extra's path relative to the parent movie's
        /// containing folder, captured at marking time. A sibling
        /// extra has just the basename (e.g. `Making-Of.mkv`); a
        /// nested extra has the in-between folders too (e.g.
        /// `Extras-Grym/Doc.mkv`). At move-time we resolve this
        /// against the parent's *current* folder first; if missing,
        /// we fall back to the source root (covers
        /// createFolderAndMove cases where the main moved into a
        /// new wrapper but the extra stayed put).
        var relativeToParentDir: String
    }

    /// Files the user checked as "Extra" in the Multiple Videos step,
    /// keyed by their path at marking time. The key is only used by
    /// the UI checkbox binding — move-time routing discovers each
    /// file via `ExtraMark` instead, so a folder rename between
    /// marking and move doesn't break attribution.
    private(set) var extrasMarks: [String: ExtraMark] = [:]

    /// Outcomes accumulated by `RenameModel.apply` for each successful
    /// extras relocation. Read at Move-to-Library time to write the
    /// final library-path rows into the `extras` table after the
    /// wrappers have moved.
    private var recordedExtraRelocations: [ExtraRelocationOutcome] = []

    /// Marks / unmarks one file as an Extra. Passing `mark = nil`
    /// clears the entry. Called from the Duplicates view's per-row
    /// Extra checkbox.
    func setExtraMark(_ mark: ExtraMark?, forPath path: String) {
        if let mark {
            extrasMarks[path] = mark
        } else {
            extrasMarks.removeValue(forKey: path)
        }
    }

    // MARK: - MovieScope extras conformance

    /// One request per marked Extra, surfaced to the RenameModel so
    /// it can fold extras into its plan as first-class rows
    /// alongside the matched movies.
    var pendingExtras: [ExtraRenameRequest] {
        extrasMarks.map { (key, mark) in
            ExtraRenameRequest(
                markedPath: key,
                filename: mark.filename,
                size: mark.size,
                parentTMDBId: mark.parentTMDBId,
                relativeToParentDir: mark.relativeToParentDir
            )
        }
    }

    /// Accumulate a successful extras relocation. Move-to-Library
    /// reads `recordedExtraRelocations` after the rescan to insert
    /// `extras` table rows under each file's final library path.
    func recordExtraRelocation(_ outcome: ExtraRelocationOutcome) {
        recordedExtraRelocations.append(outcome)
    }

    /// Identifies the parent movie for a candidate-extra path. Uses
    /// **directory ancestry**: a matched movie is a parent iff its
    /// containing folder is an ancestor of (or equal to) the extra's
    /// containing folder. That handles all the natural layouts —
    /// sibling-of-main, dedicated `Extras/` subfolder, and
    /// parent-dir-with-multiple-release-folders — without forcing
    /// the user to think about buckets.
    ///
    /// When multiple matched movies qualify (e.g. nested release
    /// folders), the deepest match wins so the user gets attached
    /// to the most specific main; ties broken by file size so the
    /// chunkier video wins. Returns nil when no matched ancestor
    /// exists (the row IS the main, or no main is matched yet).
    func parentMovie(forSourcePath path: String) -> MovieFile? {
        guard !sourceDirectory.isEmpty else { return nil }
        let sourcePrefix = sourceDirectory.hasSuffix("/")
            ? sourceDirectory : sourceDirectory + "/"
        guard path.hasPrefix(sourcePrefix) else { return nil }
        let extraDir = (path as NSString).deletingLastPathComponent
        let candidates = movies.filter { movie in
            guard movie.path.hasPrefix(sourcePrefix),
                  movie.path != path,
                  movie.tmdbId != nil
            else { return false }
            let mainDir = (movie.path as NSString).deletingLastPathComponent
            if extraDir == mainDir { return true }
            let mainDirPrefix = mainDir.hasSuffix("/") ? mainDir : mainDir + "/"
            return extraDir.hasPrefix(mainDirPrefix)
        }
        return candidates.max(by: { a, b in
            let aDepth = a.path.filter { $0 == "/" }.count
            let bDepth = b.path.filter { $0 == "/" }.count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.size < b.size
        })
    }

    // MARK: - Step 7: Move to Library

    /// Final action. Moves *only the items this import is responsible for*
    /// into the live library directory, then triggers a rescan + re-applies
    /// the TMDB matches for the moved files.
    ///
    /// "Items this import is responsible for" = each in-memory movie's
    /// first path component beneath `sourceDirectory`. After the rename
    /// step that's typically a canonical wrapper folder like
    /// `<title> (<year>) {tmdb-N}`. Anything else in the source —
    /// manually-organized extras subfolders, leftover NFOs, `.DS_Store`,
    /// release artwork — gets left where it is. We never touched it, so
    /// we don't move it.
    ///
    /// Safe to call multiple times — items already in the library are
    /// skipped. Bails early with `lastError` set if the library
    /// destination isn't configured or if a target already exists.
    func moveToLibrary() async {
        guard !isBusy else { return }
        guard appModel.hasDirectory else {
            lastError = "Library directory isn't set — open one from the main window first."
            return
        }
        let destination = appModel.directoryPath
        let sourceStd = URL(fileURLWithPath: sourceDirectory).standardizedFileURL.path
        let destStd = URL(fileURLWithPath: destination).standardizedFileURL.path
        guard sourceStd != destStd else {
            lastError = "Source and library directories are the same — pick a different source."
            return
        }

        isBusy = true
        busyMessage = "Moving to library…"
        defer {
            isBusy = false
            busyMessage = ""
        }

        // Honor any Replace marks the user committed at the Match step
        // BEFORE touching the source files. Deletes the existing library
        // wrapper / video / sidecars so the new copy can slot into the
        // same canonical path on disk. Skipped when no marks are set;
        // skipped per-row for marks that no longer resolve to a live
        // duplicate (the user re-picked the TMDB candidate after
        // marking).
        if !replaceMarkedPaths.isEmpty {
            busyMessage = "Removing existing copies…"
            await performReplacements()
            busyMessage = "Moving to library…"
        }

        // Extras have already been relocated by the Rename step into
        // each parent's `Other/` subfolder inside the source tree, so
        // they ride along when the wrapper moves below. We just need
        // the recorded outcomes for the post-rescan DB write further
        // down.
        let extrasRelocations = recordedExtraRelocations

        let fm = FileManager.default
        // Compute the in-scope top-level items: each tracked movie's first
        // path component beneath the source. Using a Set so two videos
        // sharing a wrapper folder don't produce two move attempts.
        let sourcePrefix = sourceDirectory.hasSuffix("/") ? sourceDirectory : sourceDirectory + "/"
        let itemsToMove: Set<String> = Set(
            movies.compactMap { movie -> String? in
                guard movie.path.hasPrefix(sourcePrefix) else { return nil }
                let relative = String(movie.path.dropFirst(sourcePrefix.count))
                if let slash = relative.firstIndex(of: "/") {
                    return String(relative[..<slash])
                }
                // Loose file directly at the source root — move just the
                // file. Sidecars only travel along if the user ran the
                // rename step, which gathers them into a wrapper folder.
                return relative
            }
        )
        guard !itemsToMove.isEmpty else {
            lastError = "No imported items to move — nothing in this session has a path inside \(sourceDirectory)."
            return
        }
        let sortedItems = itemsToMove.sorted()

        // Track success: post-move path of each in-memory movie so we
        // can re-apply TMDB matches after the rescan.
        var rekeyedMatches: [String: (tmdbID: Int, confirmedYear: Int?, customEdition: String?)] = [:]
        var failures: [String] = []

        for item in sortedItems {
            let src = (sourceDirectory as NSString).appendingPathComponent(item)
            let dst = (destination as NSString).appendingPathComponent(item)
            if fm.fileExists(atPath: dst) {
                failures.append("\(item): already exists in library")
                continue
            }
            do {
                try fm.moveItem(atPath: src, toPath: dst)
            } catch {
                failures.append("\(item): \(error.localizedDescription)")
                continue
            }
            // Re-key any in-memory match that lived under `src/` to its
            // new location under `dst/`.
            let srcPrefix = src.hasSuffix("/") ? src : src + "/"
            let dstPrefix = dst.hasSuffix("/") ? dst : dst + "/"
            for (path, match) in tmdbMatches where path == src || path.hasPrefix(srcPrefix) {
                let newPath: String
                if path == src {
                    newPath = dst
                } else {
                    newPath = dstPrefix + String(path.dropFirst(srcPrefix.count))
                }
                rekeyedMatches[newPath] = match
            }
        }

        if !failures.isEmpty {
            lastError = failures.joined(separator: "\n")
        }

        // Auto-prune the source husk if requested. Triggers only when
        // every visible (non-hidden) entry inside the source directory
        // is gone — leftover NFOs / extras / unprocessed cruft leave
        // the source alone for the user to deal with manually. We use
        // `removeItem` rather than walking the tree so any hidden
        // entries (`.DS_Store`, `.AppleDouble`, etc.) get cleaned up
        // alongside the directory itself.
        if autoPruneSource, !sourceDirectory.isEmpty {
            let remaining = (try? fm.contentsOfDirectory(atPath: sourceDirectory)) ?? []
            let visibleEntries = remaining.filter { !$0.hasPrefix(".") }
            if visibleEntries.isEmpty {
                try? fm.removeItem(atPath: sourceDirectory)
            }
        }

        // Pick up the moved files in the live library, then re-apply
        // the TMDB matches by path.
        await appModel.rescan()
        if let store = appModel.store {
            for (path, match) in rekeyedMatches {
                try? store.setTMDBMatch(
                    forPath: path,
                    tmdbID: match.tmdbID,
                    confirmedYear: match.confirmedYear,
                    customEdition: match.customEdition
                )
            }
            // Persist every successfully-relocated extra under its
            // final library path. We compute the library path by
            // swapping the source-directory prefix for the
            // destination-directory prefix — the relocations sit
            // inside wrappers that just moved as part of the loop
            // above.
            recordRelocatedExtras(
                extrasRelocations,
                sourcePrefix: sourcePrefix,
                destination: destination,
                store: store
            )
            appModel.reloadFromStore()
        }

        // Reset our in-memory state and signal completion.
        let movedCount = rekeyedMatches.count
        movies = []
        tmdbMatches.removeAll()
        extrasMarks.removeAll()
        recordedExtraRelocations.removeAll()
        sourceDirectory = ""
        currentStep = .done
        if movedCount > 0, lastError == nil {
            lastError = nil
        }
    }

    // MARK: - Extras DB-record helper

    /// Persists each relocated extra to the `extras` table under its
    /// final library path. Library path = swap `sourcePrefix` for the
    /// library destination prefix — the wrappers have already moved
    /// by the time this runs, carrying the `Other/<extra>` files
    /// along.
    ///
    /// Inputs come from `recordedExtraRelocations`, accumulated as
    /// the RenameModel processed extras rows at step 7. We don't
    /// re-do filesystem work here.
    private func recordRelocatedExtras(
        _ relocations: [ExtraRelocationOutcome],
        sourcePrefix: String,
        destination: String,
        store: MovieStore
    ) {
        guard !relocations.isEmpty else { return }
        let destPrefix = destination.hasSuffix("/") ? destination : destination + "/"
        let now = Date().timeIntervalSince1970
        for relocation in relocations {
            guard relocation.sourceAfterMove.hasPrefix(sourcePrefix),
                  relocation.parentSourcePath.hasPrefix(sourcePrefix)
            else { continue }
            let extraRelative = String(
                relocation.sourceAfterMove.dropFirst(sourcePrefix.count)
            )
            let parentRelative = String(
                relocation.parentSourcePath.dropFirst(sourcePrefix.count)
            )
            let libraryPath = destPrefix + extraRelative
            let parentLibraryPath = destPrefix + parentRelative
            try? store.addExtra(ExtraFile(
                path: libraryPath,
                parentMoviePath: parentLibraryPath,
                parentTMDBId: relocation.parentTMDBId,
                category: "Other",
                filename: relocation.filename,
                size: relocation.size,
                addedAt: now
            ))
        }
    }

    // MARK: - Step enum

    /// Ordered phases of the import wizard.
    enum Step: Int, CaseIterable, Identifiable {
        case pickDirectory
        case match
        case images
        case text
        case multiVideo
        case emptyFolders
        case rename
        case ready
        case done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .pickDirectory: return "Pick Source"
            case .match: return "Match TMDB"
            case .images: return "Images"
            case .text: return "Text / NFO"
            case .multiVideo: return "Multiple Videos"
            case .emptyFolders: return "Empty Folders"
            case .rename: return "Rename"
            case .ready: return "Ready"
            case .done: return "Done"
            }
        }

        var next: Step? {
            guard let nextRaw = Step(rawValue: rawValue + 1) else { return nil }
            return nextRaw
        }

        var previous: Step? {
            guard rawValue > 0, let prev = Step(rawValue: rawValue - 1) else { return nil }
            return prev
        }
    }
}
