import Foundation
import Observation

/// Orchestrates a *Smart Import*: an automated run of the manual import
/// pipeline against the watch directory. It composes the same pieces the
/// import wizard uses — an `ImportSession` (the `MovieScope` + the
/// move-to-library machinery), a `MatcherModel`, and a `RenameModel` — but
/// runs match → cleanup-planning → extras-defaults headlessly, leaving the
/// user only two panes: a Multiple-Videos review and a final Ready preview.
///
/// Every destructive action (deleting images / text / sample videos / empty
/// folders, renaming, moving) is deferred to `execute()`, which fires only
/// when the user confirms at the Ready step. Nothing is touched on disk during
/// `prepare()` except the TMDB cache + poster cache the matcher fills.
@MainActor
@Observable
final class SmartImportModel {
    enum Phase {
        case preparing
        case needsWatchDir
        case nothingToImport
        case review
        case ready
        case importing
        case done
        case error
    }

    private let appModel: AppModel
    private let monitor: SmartImportMonitor

    /// The shared session — `MovieScope` for the matcher/rename and the owner
    /// of `moveToLibrary`. Recreated implicitly each `prepare` via
    /// `setSourceDirectory`, which clears its state.
    let session: ImportSession
    /// Rename plan, surfaced to the Ready preview (before → after) and applied
    /// during `execute`.
    let rename: RenameModel

    private(set) var phase: Phase = .preparing
    var lastError: String?

    /// Image files we'll delete, scoped to the folders of matched movies.
    private(set) var imageDeletions: [ScannedFile] = []
    /// Text / NFO files we'll delete, same scoping.
    private(set) var textDeletions: [ScannedFile] = []

    /// Multiple-Videos buckets shown in the review pane — only subfolder
    /// buckets that contain a matched movie *and* at least one other video to
    /// decide on. Loose root-level videos are never shown (a loose match is
    /// its own movie; a loose non-match is left untouched).
    private(set) var groups: [DuplicateGroup] = []

    /// Final set of non-main videos the user has marked for deletion (samples
    /// are pre-seeded here). Bound from the review pane; read at execute time
    /// and shown struck-through in the Ready preview.
    var videoDeleteSelection: Set<String> = []

    /// Paths of videos confirmed as matched movies. Drives "is this the main?"
    /// in the review pane.
    private(set) var matchedPaths: Set<String> = []

    /// When true, matched movies that already exist in the library
    /// (`libraryDuplicates`) have their existing copy permanently deleted
    /// before the new one moves in — the import wizard's Replace flow (§6.7),
    /// driven from a checkbox on the Ready step. Off by default because the
    /// deletion is permanent (no Trash); when off, those movies are skipped.
    var replaceExisting = false

    init(appModel: AppModel, monitor: SmartImportMonitor) {
        self.appModel = appModel
        self.monitor = monitor
        let session = ImportSession(appModel: appModel)
        self.session = session
        self.rename = RenameModel(scope: session)
    }

    var watchDirectory: String { monitor.watchDirectory }

    /// Matched movies, title-sorted — the Ready preview's TMDB section.
    var matchedMovies: [MovieFile] {
        session.movies
            .filter { $0.tmdbId != nil }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    var totalDeletionCount: Int {
        imageDeletions.count + textDeletions.count + videoDeleteSelection.count
    }

    /// Rename rows that collide on the same destination path — two downloads
    /// that matched the same movie which we can't tell apart (Smart Import
    /// doesn't run ffprobe, so the `[qualityTag]` split can't differentiate
    /// them). They start unchecked, so the headless apply skips them. Surfaced
    /// so the user isn't left wondering why a file didn't import.
    var conflictingRows: [RenameModel.Row] {
        rename.rows.filter { $0.duplicateConflict }
    }

    /// Matched movies whose TMDB id + edition already exist in the live
    /// library. `moveToLibrary` never overwrites, so these fail the move and
    /// stay in the watch dir — flag them up front. Use the regular Import
    /// window's Replace flow to swap an existing copy.
    var libraryDuplicates: [ImportSession.DuplicateConflict] {
        session.duplicateConflicts
    }

    var hasConflicts: Bool { !conflictingRows.isEmpty || !libraryDuplicates.isEmpty }

    // MARK: - Prepare (no disk mutations except TMDB/poster cache)

    /// Runs the automated front half of the pipeline: scan → confident TMDB
    /// match → compute the image/text deletion plan → seed extras / sample
    /// defaults. Lands on `.review` (or `.ready` when there's nothing to
    /// review). Safe to re-run; clears prior state via `setSourceDirectory`.
    func prepare() async {
        phase = .preparing
        lastError = nil
        videoDeleteSelection.removeAll()
        groups = []
        imageDeletions = []
        textDeletions = []
        matchedPaths = []

        let watchDir = monitor.watchDirectory
        guard !watchDir.isEmpty else { phase = .needsWatchDir; return }
        guard TMDBService.apiKey != nil else {
            lastError = "Set a TMDB API key in Settings before using Smart Import."
            phase = .error
            return
        }

        await session.setSourceDirectory(watchDir)
        guard !session.movies.isEmpty else { phase = .nothingToImport; return }

        // Confident auto-match only. Uncertain / unmatched rows are never
        // confirmed, so they keep `tmdbId == nil` and fall out of every
        // downstream step — left untouched in the watch dir.
        let matcher = MatcherModel(scope: session, autoCommitOnPick: true)
        matcher.reload()
        await matcher.runScan()
        await matcher.confirm()

        matchedPaths = Set(session.movies.filter { $0.tmdbId != nil }.map(\.path))
        // Correct the toolbar button to what this fresh scan actually found.
        monitor.updatePendingCount(matchedPaths.count)
        guard !matchedPaths.isEmpty else { phase = .nothingToImport; return }

        // Folders (one level beneath the watch dir) that hold a matched movie.
        // Loose matched files at the root contribute no folder, so their
        // surroundings are never swept.
        let trackedDirs = trackedTopLevelDirs(of: matchedPaths)

        // Image + text deletions, scoped to those folders only.
        let extImages = CleanupCategory.images.extensions
        let extText = CleanupCategory.text.extensions
        let (images, texts) = await Task.detached(priority: .userInitiated) {
            var imgs: [ScannedFile] = []
            var txts: [ScannedFile] = []
            for dir in trackedDirs {
                let url = URL(fileURLWithPath: dir)
                imgs.append(contentsOf: FileScanner.scan(directory: url, extensions: extImages))
                txts.append(contentsOf: FileScanner.scan(directory: url, extensions: extText))
            }
            return (imgs, txts)
        }.value
        imageDeletions = images.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        textDeletions = texts.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        buildReviewGroups(watchDir: watchDir)
        seedReviewDefaults()

        if groups.isEmpty {
            await rename.reload()
            phase = .ready
        } else {
            phase = .review
        }
    }

    /// Review → Ready. Rebuilds the rename plan so it reflects whatever extras
    /// the user (un)checked, then shows the preview.
    func proceedToReady() async {
        await rename.reload()
        phase = .ready
    }

    func backToReview() {
        phase = .review
    }

    // MARK: - Review pane helpers

    func isMain(_ file: ScannedFile) -> Bool { matchedPaths.contains(file.path) }
    func isExtra(_ file: ScannedFile) -> Bool { session.extrasMarks[file.path] != nil }
    func isMarkedForDeletion(_ file: ScannedFile) -> Bool { videoDeleteSelection.contains(file.path) }
    func isExtraEligible(_ file: ScannedFile) -> Bool {
        session.parentMovie(forSourcePath: file.path) != nil
    }

    /// Toggle the Extra mark. Mutually exclusive with Delete (matches the
    /// import wizard's Multiple-Videos contract).
    func setExtra(_ file: ScannedFile, _ on: Bool) {
        if on {
            markExtra(file)
            videoDeleteSelection.remove(file.path)
        } else {
            session.setExtraMark(nil, forPath: file.path)
        }
    }

    func setDeletion(_ file: ScannedFile, _ on: Bool) {
        if on {
            videoDeleteSelection.insert(file.path)
            session.setExtraMark(nil, forPath: file.path)
        } else {
            videoDeleteSelection.remove(file.path)
        }
    }

    // MARK: - Execute (all deletes + rename + move happen here)

    func execute() async {
        guard phase == .ready else { return }
        phase = .importing
        lastError = nil
        var failures: [String] = []

        // 1–3. Permanent deletes: images, text, then marked videos (samples
        // + any the user checked). Per the app's no-Trash design (§6.8).
        let deletePaths = imageDeletions.map(\.path)
            + textDeletions.map(\.path)
            + Array(videoDeleteSelection)
        let deleteFailures = await Self.removeItems(deletePaths)
        failures.append(contentsOf: deleteFailures)

        // 4. Rename matched movies into canonical wrappers + relocate extras.
        await rename.apply()
        if let renameError = rename.lastError, !renameError.isEmpty {
            failures.append(renameError)
        }

        // 5. Prune folders left empty inside the (now-renamed) matched
        // wrappers. Scoped to those wrappers so untouched / unmatched areas of
        // the watch dir are never swept.
        let wrappers = trackedTopLevelDirs(of: Set(session.movies.filter { $0.tmdbId != nil }.map(\.path)))
        let emptyPaths = await Task.detached(priority: .userInitiated) {
            wrappers.flatMap { EmptyFoldersModel.findEmptyRoots(under: $0).map(\.path) }
        }.value
        _ = await Self.removeItems(emptyPaths)

        // Replace existing library copies when the user opted in. Marking the
        // (post-rename) imported paths routes `moveToLibrary` through the
        // session's Replace flow — it deletes each existing copy before the
        // new one moves into the freed canonical path. Without this the move
        // would fail on the occupied destination and the movie would be left
        // in the watch dir.
        if replaceExisting {
            for dup in session.duplicateConflicts {
                session.setReplace(true, forPath: dup.imported.path)
            }
        }

        // 6. Move matched wrappers into the library (rescan + match re-apply +
        // extras DB rows + watch-dir husk prune all handled by the session).
        session.autoPruneSource = true
        await session.moveToLibrary()
        if let moveError = session.lastError, !moveError.isEmpty {
            failures.append(moveError)
        }

        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        phase = .done

        // Clear / refresh the blue toolbar indicator now the watch dir drained.
        await monitor.scanNow()
    }

    // MARK: - Export plan

    /// Builds a plain-text (Markdown) report of the whole pending import — the
    /// TMDB matches, every rename, every deletion, and a full annotated
    /// inventory of the watch directory — suitable for copying into an LLM to
    /// work through anything that looks off. Walks the filesystem off the main
    /// actor; everything else is read from already-computed state.
    func exportPlanText() async -> String {
        let watchDir = monitor.watchDirectory

        // Full file inventory (every regular file, not just videos), sized.
        let rawFiles: [FileEntry] = await Task.detached(priority: .userInitiated) {
            Self.walkAllFiles(under: watchDir)
        }.value

        let imageSet = Set(imageDeletions.map(\.path))
        let textSet = Set(textDeletions.map(\.path))
        let prefix = watchDir.hasSuffix("/") ? watchDir : watchDir + "/"
        func relative(_ path: String) -> String {
            path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        func size(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }

        var lines: [String] = []
        lines.append("# Smart Import Plan")
        lines.append("")
        lines.append("- Watch directory: \(watchDir.isEmpty ? "(not set)" : watchDir)")
        lines.append("- Library destination: \(appModel.hasDirectory ? appModel.directoryPath : "(not set)")")
        lines.append("- Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // TMDB matches
        lines.append("## TMDB matches (\(matchedMovies.count))")
        if matchedMovies.isEmpty {
            lines.append("_none_")
        } else {
            for movie in matchedMovies {
                let id = movie.tmdbId.map { "{tmdb-\($0)}" } ?? ""
                let type = movie.movieType.map { " · \($0)" } ?? ""
                lines.append("- \(movie.displayTitle) \(id)\(type) · \(size(movie.size))")
                lines.append("  - source: \(relative(movie.path))")
            }
        }
        lines.append("")

        // Renames
        lines.append("## Renames (\(rename.rows.count))")
        if rename.rows.isEmpty {
            lines.append("_none_")
        } else {
            for row in rename.rows {
                let tag = row.extraInfo.map { " [extra → parent tmdb-\($0.parentTMDBId)]" } ?? ""
                lines.append("- BEFORE: \(row.currentDisplay)\(tag)")
                lines.append("  AFTER:  \(row.proposedDisplay)")
                if !row.subtitles.isEmpty {
                    lines.append("  subtitles: \(row.subtitles.count)")
                }
            }
        }
        lines.append("")

        // Deletions
        let deletedVideos = groups.flatMap(\.files).filter { videoDeleteSelection.contains($0.path) }
        let deletionTotal = imageDeletions.count + textDeletions.count + deletedVideos.count
        lines.append("## Files to delete (\(deletionTotal)) — permanent, no Trash")
        if deletionTotal == 0 {
            lines.append("_none_")
        } else {
            for file in imageDeletions { lines.append("- [image] \(relative(file.path)) · \(size(file.size))") }
            for file in textDeletions { lines.append("- [text]  \(relative(file.path)) · \(size(file.size))") }
            for file in deletedVideos { lines.append("- [video] \(relative(file.path)) · \(size(file.size))") }
        }
        lines.append("")

        // Conflicts / needs attention
        lines.append("## Needs attention")
        if !hasConflicts {
            lines.append("_none_")
        } else {
            for row in conflictingRows {
                lines.append("- COLLISION (skipped — two downloads matched the same movie): \(relative(row.path))")
                lines.append("  would-be target: \(row.proposedDisplay)")
            }
            let dupAction = replaceExisting ? "existing copy will be REPLACED" : "move will be SKIPPED"
            for dup in libraryDuplicates {
                lines.append("- ALREADY IN LIBRARY (\(dupAction)): \(dup.imported.displayTitle)")
                for existing in dup.existing {
                    lines.append("  existing copy: \(existing.path)")
                }
            }
        }
        lines.append("")

        // Full annotated inventory
        lines.append("## Watch directory contents (\(rawFiles.count))")
        for file in rawFiles {
            let role: String
            if matchedPaths.contains(file.path) {
                role = "matched movie"
            } else if session.extrasMarks[file.path] != nil {
                role = "extra"
            } else if videoDeleteSelection.contains(file.path) {
                role = "delete (video)"
            } else if imageSet.contains(file.path) {
                role = "delete (image)"
            } else if textSet.contains(file.path) {
                role = "delete (text)"
            } else {
                role = "untouched"
            }
            lines.append("- \(relative(file.path)) · \(size(file.size)) · \(role)")
        }

        return lines.joined(separator: "\n")
    }

    private struct FileEntry: Sendable {
        let path: String
        let size: Int64
    }

    /// Synchronous full-tree walk (every regular file, sized), name-sorted.
    /// Kept synchronous + `nonisolated` so the `FileManager` enumerator isn't
    /// iterated from an async context (`makeIterator` is unavailable there).
    private nonisolated static func walkAllFiles(under directory: String) -> [FileEntry] {
        var out: [FileEntry] = []
        let url = URL(fileURLWithPath: directory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                out.append(FileEntry(path: fileURL.path, size: Int64(values?.fileSize ?? 0)))
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Helpers

    /// Absolute paths of the one-level-deep folders beneath the watch dir that
    /// contain any of `paths`. Loose files directly at the root yield no
    /// folder and are skipped.
    private func trackedTopLevelDirs(of paths: Set<String>) -> Set<String> {
        let source = session.sourceDirectory
        guard !source.isEmpty else { return [] }
        let prefix = source.hasSuffix("/") ? source : source + "/"
        var dirs: Set<String> = []
        for path in paths {
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard let slash = relative.firstIndex(of: "/") else { continue }
            let component = String(relative[..<slash])
            dirs.insert((source as NSString).appendingPathComponent(component))
        }
        return dirs
    }

    /// Subfolder buckets that hold a matched movie AND at least one other video
    /// to decide on. Excludes the synthetic root bucket and single-main
    /// folders (nothing to review there).
    private func buildReviewGroups(watchDir: String) {
        let videos = FileScanner.scan(
            directory: URL(fileURLWithPath: watchDir),
            extensions: DirectoryScanner.movieExtensions
        )
        let all = DuplicatesModel.group(files: videos, root: watchDir, includeRootLevel: true)
        let watchStd = URL(fileURLWithPath: watchDir).standardizedFileURL.path
        groups = all.filter { group in
            group.directory != watchStd
                && group.files.contains { matchedPaths.contains($0.path) }
                && group.files.contains { !matchedPaths.contains($0.path) }
        }
    }

    /// Default marks for the review pane: every non-main video in a shown
    /// bucket is flagged **Extra**, except ones whose path reads as a sample,
    /// which are flagged **Delete** instead.
    private func seedReviewDefaults() {
        for group in groups {
            for file in group.files where !matchedPaths.contains(file.path) {
                if isSample(file) {
                    videoDeleteSelection.insert(file.path)
                } else if isExtraEligible(file) {
                    markExtra(file)
                }
            }
        }
    }

    /// A video "looks like a sample" when its path beneath the watch dir
    /// mentions `sample`. We scope the check to the relative path (not the
    /// absolute one) so a watch dir that itself happens to contain "sample"
    /// doesn't tar every file.
    private func isSample(_ file: ScannedFile) -> Bool {
        let source = session.sourceDirectory
        let prefix = source.hasSuffix("/") ? source : source + "/"
        let relative = file.path.hasPrefix(prefix)
            ? String(file.path.dropFirst(prefix.count))
            : file.filename
        return relative.lowercased().contains("sample")
    }

    /// Records an Extra mark for `file`, attributing it to its parent movie.
    /// Mirrors `ImportView.makeExtrasConfig`'s relative-path capture so
    /// move-time discovery works whether the extra is a sibling-of-main or
    /// nested in a subfolder.
    private func markExtra(_ file: ScannedFile) {
        guard let parent = session.parentMovie(forSourcePath: file.path),
              let tmdbId = parent.tmdbId
        else { return }
        let parentDir = (parent.path as NSString).deletingLastPathComponent
        let parentDirPrefix = parentDir.hasSuffix("/") ? parentDir : parentDir + "/"
        let relative = file.path.hasPrefix(parentDirPrefix)
            ? String(file.path.dropFirst(parentDirPrefix.count))
            : file.filename
        session.setExtraMark(
            ImportSession.ExtraMark(
                filename: file.filename,
                size: file.size,
                parentTMDBId: tmdbId,
                relativeToParentDir: relative
            ),
            forPath: file.path
        )
    }

    /// Permanently deletes each path (no Trash, §6.8). Returns per-path failure
    /// messages. Runs the filesystem work off the main actor.
    private static func removeItems(_ paths: [String]) async -> [String] {
        guard !paths.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var failures: [String] = []
            for path in paths {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    failures.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            return failures
        }.value
    }
}
