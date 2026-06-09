import Foundation

/// Backs the "Rename Library" window. Builds the rename plan for every
/// already-matched movie, lets the user uncheck rows, then renames the
/// files + folders on disk and rewires the SQLite primary key in step.
@MainActor
@Observable
final class RenameModel {
    /// One row in the rename table.
    struct Row: Identifiable, Equatable {
        /// Current absolute path of the movie file (primary key).
        let path: String
        /// Current filename only, e.g. "Some.Film.2020.UHD.Remux.mkv".
        let currentFilename: String
        /// Path relative to the scan root for display (full path if the
        /// movie sits outside the root for any reason).
        let currentDisplay: String
        /// Display version of the post-rename path.
        let proposedDisplay: String
        /// Absolute target path for the movie file after the rename.
        let newPath: String
        /// Absolute target path for the wrapping folder.
        let newFolderPath: String
        /// Absolute path of the movie's current immediate parent.
        let oldFolderPath: String
        /// Filename portion of `newPath`.
        let newFilename: String
        /// What kind of disk operation this row needs.
        let plan: Plan
        /// Did the source filename / path indicate a Remux source? Drives
        /// the `[Remux]` tag preservation on the new filename.
        let isRemux: Bool
        /// True when the *current* path contains any of the filesystem
        /// trouble chars the sanitizer rewrites — used to sort these rows
        /// to the top.
        let hasSpecialCharacters: Bool
        /// True when this row competes with one or more other rows for the
        /// exact same destination path (i.e. two different source files
        /// matched to the same TMDB ID). Surfaced in the UI as a red
        /// "duplicate" chip, and these rows start unchecked so the user
        /// is forced to reconcile before Apply rather than silently
        /// failing the second one with `targetFolderExists`.
        var duplicateConflict: Bool = false
        /// Whether this row will be applied on the next Apply pass.
        var included: Bool = true
        var status: Status = .pending
        var failureReason: String?
        /// Sidecar subtitle files associated with this video — get renamed
        /// + moved alongside the video during Apply.
        var subtitles: [SubtitleAsset] = []

        var id: String { path }

        enum Status: Equatable {
            case pending
            case succeeded
            case failed
        }

        enum Plan: Equatable {
            /// Rename the immediate parent folder, then the file inside it.
            case renameFolder
            /// Movie was loose at the scan root — create a wrapping folder
            /// and move the file into it.
            case createFolderAndMove
        }
    }

    /// One sibling subtitle file (or one entry inside a `Subs/`-style
    /// subfolder) that travels with a renamed video.
    struct SubtitleAsset: Identifiable, Equatable {
        /// Absolute path captured at plan-build time.
        let path: String
        /// Absolute target path after Apply runs.
        let newPath: String
        /// Name of the original Subs-style container, if the file lived in
        /// one. nil for siblings directly next to the video. Used at apply
        /// time to canonicalize the folder to `Subs/` before renaming the
        /// file inside it.
        let originalContainer: String?
        let language: String?
        let isForced: Bool
        let isSDH: Bool
        /// Optional descriptor distinguishing multiple same-language
        /// tracks (`commentary`, `simplified`, `brazilian`, …). nil for
        /// the primary track.
        let descriptor: String?
        /// True iff this asset's filename ended up with a numeric `.N`
        /// suffix because the originally-composed name was already taken
        /// by another asset on the same row. Surfaced in the UI so the
        /// user can manually rename to something meaningful (e.g.
        /// `.en.2.srt` → `.en.commentary.srt`).
        let collisionSuffix: Bool
        var status: Status = .pending
        var failureReason: String?
        /// Soft warning surfaced in the preview — set at plan-build for
        /// things that aren't strictly errors but the user might want to
        /// review (e.g. an untagged sibling sub when the Subs/ folder
        /// already carries language-tagged tracks: probably a duplicate
        /// content-wise, but our composed names don't collide so Apply
        /// would still go through unless the user unchecks the row).
        var warningReason: String?

        var id: String { path }

        enum Status: Equatable {
            case pending, succeeded, failed
        }
    }

    private(set) var rows: [Row] = []
    private(set) var isApplying = false
    /// True while `reload()` is still building the plan — surfaces a
    /// progress indicator in the UI for slow network volumes where the
    /// per-row directory enumeration takes a moment.
    private(set) var isLoading = false
    /// 0...1 progress for the active build (during `reload`) or apply
    /// (during `apply`). Single field — never both running at once.
    private(set) var progress: Double = 0
    /// Number of movies inspected so far during `reload`. Drives the
    /// "Building plan: M / N" line.
    private(set) var loadProcessed: Int = 0
    /// Total movies we'll inspect during this `reload` pass.
    private(set) var loadTotal: Int = 0
    /// Index of the row currently being applied — drives highlight + the
    /// "currently renaming" line.
    private(set) var currentIndex: Int?
    /// Live path of the row currently being renamed, surfaced in the UI.
    private(set) var currentPath: String?
    var lastError: String?

    private let scope: any MovieScope

    init(scope: any MovieScope) {
        self.scope = scope
    }

    // MARK: - Derived

    var includedCount: Int {
        rows.lazy.filter { $0.included }.count
    }

    var allIncluded: Bool {
        !rows.isEmpty && rows.allSatisfy { $0.included }
    }

    // MARK: - Plan build

    /// Rebuilds `rows` from the current AppModel + TMDB cache. Called on
    /// every window appear so a fresh rescan or new TMDB matches are
    /// reflected. Async so the per-row directory enumeration (slow on
    /// network volumes) can yield to the main actor and keep the UI
    /// responsive — driving the loading spinner + progress bar.
    func reload() async {
        guard !isLoading else { return }
        guard let store = scope.store else {
            rows = []
            return
        }
        isLoading = true
        progress = 0
        loadProcessed = 0
        loadTotal = scope.movies.count
        defer {
            isLoading = false
            progress = 0
        }
        let scanRoot = scope.directoryPath

        // Count siblings per parent directory so we can skip multi-video
        // folders (renaming the shared folder would break the other movies).
        var siblingCounts: [String: Int] = [:]
        for movie in scope.movies {
            let parent = (movie.path as NSString).deletingLastPathComponent
            siblingCounts[parent, default: 0] += 1
        }

        var detailCache: [Int: TMDBMovieDetail] = [:]
        var newRows: [Row] = []

        let rootStd = URL(fileURLWithPath: scanRoot).standardizedFileURL.path

        // Build a one-time index of subtitle files at the scan root so loose
        // (`.createFolderAndMove`) videos can claim their sibling subtitles
        // by filename-stem prefix without rescanning the root per row.
        let rootSubtitleIndex = Self.scanForSubtitles(directory: scanRoot, includeSubfolders: false)

        for (movieIdx, movie) in scope.movies.enumerated() {
            // Yield every 5 movies so the UI gets a chance to repaint the
            // progress indicator. The per-movie work below is mostly file
            // system I/O on a network volume, which can be slow enough
            // for the user to want feedback.
            if movieIdx % 5 == 0 {
                loadProcessed = movieIdx
                progress = loadTotal > 0 ? Double(movieIdx) / Double(loadTotal) : 0
                await Task.yield()
            }
            guard let tmdbID = movie.tmdbId else { continue }
            let detail: TMDBMovieDetail
            if let cached = detailCache[tmdbID] {
                detail = cached
            } else if let fetched = try? store.tmdbDetail(forID: tmdbID) {
                detail = fetched
                detailCache[tmdbID] = fetched
            } else {
                continue
            }

            let parent = (movie.path as NSString).deletingLastPathComponent
            let parentStd = URL(fileURLWithPath: parent).standardizedFileURL.path
            let ext = (movie.filename as NSString).pathExtension
            let isTopLevel = parentStd == rootStd
            let siblings = siblingCounts[parent, default: 1]

            let plan: Row.Plan
            let containerDir: String
            if isTopLevel {
                plan = .createFolderAndMove
                containerDir = scanRoot
            } else if siblings > 1 {
                // Folder is shared with other movies — can't rename it
                // safely. Skip for v1; flag in UI later if desired.
                continue
            } else {
                plan = .renameFolder
                containerDir = (parent as NSString).deletingLastPathComponent
            }

            // Year precedence:
            //   1. `confirmed_year` from movies — the exact year the
            //      matcher showed and the user signed off on. Wins
            //      because TMDB's search and details endpoints don't
            //      always agree (Perfect Blue / Miracle Mile).
            //   2. `detail.year` from preferredReleaseDate as a fallback
            //      for any matched row predating the confirmed_year
            //      column that the migration's parsed_year backfill
            //      didn't cover.
            //   3. nil → the canonical name drops the parens-year and
            //      leans on `{tmdb-N}` for identification.
            let year: Int? = movie.confirmedYear ?? detail.year.flatMap(Int.init)

            let isRemux = FilenameSanitizer.containsRemux(movie.path)
            let folderName = FilenameSanitizer.folderName(
                title: detail.title, year: year, tmdbID: tmdbID
            )
            let fileBase = FilenameSanitizer.fileBasename(
                title: detail.title, year: year, tmdbID: tmdbID, isRemux: isRemux
            )
            let newFilename = ext.isEmpty ? fileBase : "\(fileBase).\(ext)"
            let newFolderPath = (containerDir as NSString).appendingPathComponent(folderName)
            let newPath = (newFolderPath as NSString).appendingPathComponent(newFilename)

            // Subtitle assets — collected differently depending on plan.
            // For `.renameFolder` the entire folder is moving, so every
            // subtitle inside it belongs to this video. For
            // `.createFolderAndMove` we have to filter root-level subtitles
            // by filename-stem prefix because the loose video shares the
            // scan root with other unrelated files.
            let videoStem = (movie.filename as NSString).deletingPathExtension
            let newStem = (newFilename as NSString).deletingPathExtension
            let subtitles: [SubtitleAsset]
            switch plan {
            case .renameFolder:
                subtitles = Self.subtitlesForFolderedVideo(
                    videoFolder: parent,
                    newFolder: newFolderPath,
                    newStem: newStem
                )
            case .createFolderAndMove:
                subtitles = Self.subtitlesForLooseVideo(
                    videoStem: videoStem,
                    newFolder: newFolderPath,
                    newStem: newStem,
                    candidates: rootSubtitleIndex
                )
            }

            // Already canonical and no subtitle work to do — skip. Both
            // halves must be at their proposed paths: empty subtitle list
            // is the trivial case, but a populated list where every entry
            // already sits at its target counts too (e.g. a freshly-
            // imported release that was already named to our convention).
            let allSubtitlesCanonical = subtitles.allSatisfy { $0.path == $0.newPath }
            if newPath == movie.path && allSubtitlesCanonical { continue }

            let currentDisplay = Self.displayPath(movie.path, rootStd: rootStd)
            let proposedDisplay = Self.displayPath(newPath, rootStd: rootStd)
            let hasSpecial = FilenameSanitizer.hasSpecialCharacters(movie.filename)
                || (!isTopLevel && FilenameSanitizer.hasSpecialCharacters(
                    (parent as NSString).lastPathComponent
                ))

            newRows.append(Row(
                path: movie.path,
                currentFilename: movie.filename,
                currentDisplay: currentDisplay,
                proposedDisplay: proposedDisplay,
                newPath: newPath,
                newFolderPath: newFolderPath,
                oldFolderPath: parent,
                newFilename: newFilename,
                plan: plan,
                isRemux: isRemux,
                hasSpecialCharacters: hasSpecial,
                subtitles: subtitles
            ))
        }

        // Duplicate-target detection: when two source files matched to
        // the same TMDB ID, both rows propose the identical destination
        // path. Without intervention the first row would succeed and the
        // rest would silently fail Apply with `targetFolderExists`.
        // Mark every member of a colliding group and uncheck them so the
        // user resolves the dup (delete one, match one to a different
        // TMDB id, etc.) before clicking Apply.
        var targetCounts: [String: Int] = [:]
        for row in newRows { targetCounts[row.newPath, default: 0] += 1 }
        for i in newRows.indices where (targetCounts[newRows[i].newPath] ?? 0) > 1 {
            newRows[i].duplicateConflict = true
            newRows[i].included = false
        }

        // Sort priority (highest first):
        //   1. Duplicate-target rows — two different source files matched
        //      to the same TMDB id. Hard error that blocks Apply; user
        //      must reconcile. Kept at the very top, ordered by newPath
        //      so colliding pairs land adjacent.
        //   2. Rows with a `.N` collision-suffixed subtitle — the
        //      `UniqueTargetAllocator` handed out `.2`/`.3` because two
        //      subs composed to the same name. Lossless on disk but the
        //      user probably wants to rename `.en.2.srt` to something
        //      like `.en.commentary.srt`, so float them up where they're
        //      visible.
        //   3. Rows whose source path contains filesystem-trouble
        //      characters the sanitizer is rewriting.
        //   4. Rows that have subtitles attached.
        //   5. Rows without subtitles.
        // Within each bucket: alphabetical by current display path.
        newRows.sort { a, b in
            if a.duplicateConflict != b.duplicateConflict {
                return a.duplicateConflict && !b.duplicateConflict
            }
            if a.duplicateConflict, a.newPath != b.newPath {
                return a.newPath.localizedStandardCompare(b.newPath) == .orderedAscending
            }
            let aHasSuffix = a.subtitles.contains { $0.collisionSuffix }
            let bHasSuffix = b.subtitles.contains { $0.collisionSuffix }
            if aHasSuffix != bHasSuffix { return aHasSuffix && !bHasSuffix }
            if a.hasSpecialCharacters != b.hasSpecialCharacters {
                return a.hasSpecialCharacters && !b.hasSpecialCharacters
            }
            let aHasSubs = !a.subtitles.isEmpty
            let bHasSubs = !b.subtitles.isEmpty
            if aHasSubs != bHasSubs { return aHasSubs && !bHasSubs }
            return a.currentDisplay.localizedStandardCompare(b.currentDisplay) == .orderedAscending
        }

        rows = newRows
        loadProcessed = loadTotal
        progress = 0
        currentIndex = nil
        currentPath = nil
        lastError = nil
    }

    // MARK: - Selection

    func setIncluded(_ included: Bool, for rowID: Row.ID) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }) else { return }
        rows[idx].included = included
    }

    func setAllIncluded(_ included: Bool) {
        for idx in rows.indices {
            rows[idx].included = included
        }
    }

    // MARK: - Apply

    /// Runs the disk renames + DB rekeys serially. Each row's rename + DB
    /// update happens in sequence so a single failure doesn't poison the
    /// rest of the list.
    func apply() async {
        guard !isApplying, scope.store != nil else { return }
        let work = rows.enumerated().compactMap { (i, r) -> (Int, Row)? in
            r.included ? (i, r) : nil
        }
        guard !work.isEmpty else { return }

        isApplying = true
        progress = 0
        currentIndex = nil
        currentPath = nil
        lastError = nil
        defer {
            isApplying = false
            currentIndex = nil
            currentPath = nil
        }

        let fm = FileManager.default
        let total = work.count

        for (offset, entry) in work.enumerated() {
            let (idx, row) = entry
            currentIndex = idx
            currentPath = row.path
            progress = Double(offset) / Double(total)

            // Yield once per row so the UI can repaint the "currently
            // renaming" line before the (often quick) sync FileManager
            // calls run.
            await Task.yield()

            do {
                switch row.plan {
                case .createFolderAndMove:
                    if fm.fileExists(atPath: row.newFolderPath) {
                        throw RenameError.targetFolderExists(row.newFolderPath)
                    }
                    try fm.createDirectory(
                        atPath: row.newFolderPath,
                        withIntermediateDirectories: false
                    )
                    try fm.moveItem(atPath: row.path, toPath: row.newPath)

                case .renameFolder:
                    if fm.fileExists(atPath: row.newFolderPath),
                       row.newFolderPath != row.oldFolderPath {
                        throw RenameError.targetFolderExists(row.newFolderPath)
                    }
                    // First rename the wrapper folder, which carries every
                    // file inside (including the video) along with it.
                    // Then rename the video inside its new home.
                    if row.newFolderPath != row.oldFolderPath {
                        try fm.moveItem(atPath: row.oldFolderPath, toPath: row.newFolderPath)
                    }
                    let stagedFilePath = (row.newFolderPath as NSString)
                        .appendingPathComponent(row.currentFilename)
                    if stagedFilePath != row.newPath {
                        try fm.moveItem(atPath: stagedFilePath, toPath: row.newPath)
                    }
                }

                try scope.updatePath(
                    oldPath: row.path,
                    newPath: row.newPath,
                    newFilename: row.newFilename
                )
                rows[idx].status = .succeeded
            } catch {
                rows[idx].status = .failed
                rows[idx].failureReason = error.localizedDescription
                lastError = "\(row.currentFilename): \(error.localizedDescription)"
                // Skip the subtitle pass — the video itself didn't land,
                // so any subtitle moves would be relative to a stale path.
                continue
            }

            // Subtitle pass. Folder canonicalization first, then individual
            // file renames. Each subtitle failure is captured per-asset so
            // one bad rename doesn't poison the rest.
            applySubtitles(rowIndex: idx, fm: fm)
        }
        progress = 1

        // Pull the rekeyed paths back into the AppModel so the main window
        // shows the new on-disk locations.
        scope.reloadFromStore()
    }

    enum RenameError: LocalizedError {
        case targetFolderExists(String)
        case targetExists(String)
        case sourceMissing(String)

        var errorDescription: String? {
            switch self {
            case .targetFolderExists(let path):
                return "Target folder already exists: \(path)"
            case .targetExists(let path):
                return "Target already exists: \(path)"
            case .sourceMissing(let path):
                return "Source missing: \(path)"
            }
        }
    }

    /// Runs the subtitle moves for the row at `rowIndex`, expecting the
    /// video's folder + filename to have already been rewritten upstream.
    /// Canonicalizes any Subs-style subfolders first (one attempt per
    /// unique container, regardless of success), ensures the canonical
    /// `Subs/` folder exists when consolidation is targeting it, then
    /// renames each subtitle file. Each subtitle's status is captured
    /// individually so a single failure doesn't abort the rest.
    private func applySubtitles(rowIndex: Int, fm: FileManager) {
        guard rows.indices.contains(rowIndex) else { return }
        let row = rows[rowIndex]
        guard !row.subtitles.isEmpty else { return }

        // Step 1: rename non-canonical Subs-style folders to `Subs`. Track
        // *attempted* containers (not just successful ones) so a failed
        // rename doesn't get retried by the next subtitle with the same
        // container.
        var attemptedContainers: Set<String> = []
        for subtitle in row.subtitles {
            guard let container = subtitle.originalContainer,
                  !attemptedContainers.contains(container)
            else { continue }
            attemptedContainers.insert(container)
            // Already canonical — nothing to rename.
            guard container != SubtitleClassifier.canonicalFolderName else { continue }
            let oldSubsFolder = (row.newFolderPath as NSString)
                .appendingPathComponent(container)
            let newSubsFolder = (row.newFolderPath as NSString)
                .appendingPathComponent(SubtitleClassifier.canonicalFolderName)
            do {
                guard fm.fileExists(atPath: oldSubsFolder) else { continue }
                if fm.fileExists(atPath: newSubsFolder) {
                    throw RenameError.targetFolderExists(newSubsFolder)
                }
                try fm.moveItem(atPath: oldSubsFolder, toPath: newSubsFolder)
            } catch {
                // Mark every subtitle that depended on this folder as
                // failed — they can't be renamed without a valid parent.
                let reason = "Folder rename failed: \(error.localizedDescription)"
                for (i, s) in row.subtitles.enumerated() where s.originalContainer == container {
                    if rows[rowIndex].subtitles[i].status != .failed {
                        rows[rowIndex].subtitles[i].status = .failed
                        rows[rowIndex].subtitles[i].failureReason = reason
                    }
                }
            }
        }

        // Safety net: if any still-pending subtitle is targeting the
        // canonical Subs/ folder but it doesn't exist (e.g. sibling
        // consolidation with no original Subs folder, or the rename
        // above failed), create it. moveItem won't auto-create parents.
        let canonicalSubsFolder = (row.newFolderPath as NSString)
            .appendingPathComponent(SubtitleClassifier.canonicalFolderName)
        let needsSubsFolder = rows[rowIndex].subtitles.contains { sub in
            sub.status != .failed
                && (sub.newPath as NSString).deletingLastPathComponent == canonicalSubsFolder
        }
        if needsSubsFolder, !fm.fileExists(atPath: canonicalSubsFolder) {
            try? fm.createDirectory(
                atPath: canonicalSubsFolder,
                withIntermediateDirectories: false
            )
        }

        // Step 2: rename each subtitle file in place. Compute its current
        // post-folder-move location, then move it to its target name.
        for subIdx in row.subtitles.indices {
            // Skip ones marked failed during folder remap.
            if rows[rowIndex].subtitles[subIdx].status == .failed { continue }
            let subtitle = rows[rowIndex].subtitles[subIdx]
            let current = currentSubtitlePath(for: subtitle, row: row)
            do {
                guard fm.fileExists(atPath: current) else {
                    throw RenameError.sourceMissing(current)
                }
                if current != subtitle.newPath {
                    if fm.fileExists(atPath: subtitle.newPath) {
                        throw RenameError.targetExists(subtitle.newPath)
                    }
                    try fm.moveItem(atPath: current, toPath: subtitle.newPath)
                }
                rows[rowIndex].subtitles[subIdx].status = .succeeded
            } catch {
                rows[rowIndex].subtitles[subIdx].status = .failed
                rows[rowIndex].subtitles[subIdx].failureReason = error.localizedDescription
            }
        }
    }

    /// Where the subtitle file *currently* is on disk, given the video's
    /// wrapper folder has already moved (and possibly its Subs subfolder
    /// has been canonicalized). The stored `subtitle.path` was captured at
    /// reload time and is now stale for any sub that travelled with the
    /// wrapper.
    private func currentSubtitlePath(for subtitle: SubtitleAsset, row: Row) -> String {
        let originalFilename = (subtitle.path as NSString).lastPathComponent
        let container = subtitle.originalContainer.map { name in
            // After Step 1, the canonical name lives at `Subs`.
            name == SubtitleClassifier.canonicalFolderName
                ? name
                : SubtitleClassifier.canonicalFolderName
        }
        if let container {
            let folder = (row.newFolderPath as NSString).appendingPathComponent(container)
            return (folder as NSString).appendingPathComponent(originalFilename)
        }
        // Sibling subtitle case. For `.renameFolder` the entire wrapper
        // folder was renamed in step 1, carrying the sibling along, so
        // it now lives at `<newFolderPath>/<originalFilename>`. For
        // `.createFolderAndMove` only the *video* was moved into the
        // freshly-created wrapper — the sibling was never picked up
        // because it sits in the same directory we created the wrapper
        // inside (e.g. the scan root for a loose top-level video, or
        // the source directory in the import wizard). Use its captured
        // original path in that case so the move can actually find it.
        switch row.plan {
        case .renameFolder:
            return (row.newFolderPath as NSString).appendingPathComponent(originalFilename)
        case .createFolderAndMove:
            return subtitle.path
        }
    }

    // MARK: - Subtitle plan helpers

    /// Gathers subtitle assets for a video whose immediate parent folder is
    /// dedicated to this video. Two passes:
    ///
    ///  1. Detect whether a Subs-style subfolder exists. If yes, the
    ///     canonical layout becomes "everything inside `Subs/`", so any
    ///     sibling SRTs alongside the video get consolidated into `Subs/`
    ///     too. (Otherwise siblings stay as siblings — both layouts are
    ///     valid; we only flip when both exist.)
    ///  2. Walk every subtitle file and emit a `SubtitleAsset` for it.
    ///     When two assets compose to the same target name, the
    ///     `UniqueTargetAllocator` suffixes the second one with `.2`,
    ///     `.3`, etc. instead of failing — so legitimate duplicate-
    ///     language tracks (commentary, alternate rips) all land on
    ///     disk and the user can rename them with a meaningful descriptor
    ///     in Finder if desired.
    private static func subtitlesForFolderedVideo(
        videoFolder: String,
        newFolder: String,
        newStem: String
    ) -> [SubtitleAsset] {
        var assets: [SubtitleAsset] = []
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: videoFolder) else { return [] }
        // Sorted iteration so collision-suffix numbering is deterministic
        // across reload passes — first alphabetical wins the plain name.
        let sortedEntries = entries.sorted()

        // First pass: locate any Subs-style subfolder.
        var subsContainer: String?
        for entry in sortedEntries {
            let entryPath = (videoFolder as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir),
                  isDir.boolValue,
                  SubtitleClassifier.isSubtitleFolderAlias(entry)
            else { continue }
            subsContainer = entry
            break
        }
        let canonicalSubsFolder = (newFolder as NSString)
            .appendingPathComponent(SubtitleClassifier.canonicalFolderName)

        var allocator = UniqueTargetAllocator()

        // Sibling pass runs first so that a subtitle sitting next to the
        // video wins the un-suffixed primary name on collision — siblings
        // are the strongest "user intent" signal (manually placed there
        // to work with every player), so we prefer them over whatever
        // came in the release's Subs/ folder.
        //
        // Every subtitle — sibling or Subs-folder entry — lands inside
        // the canonical `Subs/` subfolder of the new wrapper. We don't
        // preserve the source layout's "next to the video" placement
        // because keeping the canonical Plex/Jellyfin convention uniform
        // makes the resulting library more predictable.
        for entry in sortedEntries {
            let entryPath = (videoFolder as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir),
                  !isDir.boolValue else { continue }
            let ext = (entry as NSString).pathExtension
            guard SubtitleClassifier.isSubtitleExtension(ext) else { continue }
            let asset = Self.buildAsset(
                sourcePath: entryPath,
                sourceFilename: entry,
                targetFolder: canonicalSubsFolder,
                newStem: newStem,
                originalContainer: nil,
                allocator: &allocator
            )
            assets.append(asset)
        }

        // Subs/ container pass runs second — colliding entries fall back
        // to `.2`, `.3`, … suffixes via the allocator.
        if let subsContainer {
            let subsPath = (videoFolder as NSString).appendingPathComponent(subsContainer)
            for sub in scanForSubtitles(directory: subsPath, includeSubfolders: false).sorted(by: { $0.filename < $1.filename }) {
                let asset = Self.buildAsset(
                    sourcePath: sub.path,
                    sourceFilename: sub.filename,
                    targetFolder: canonicalSubsFolder,
                    newStem: newStem,
                    originalContainer: subsContainer,
                    allocator: &allocator
                )
                assets.append(asset)
            }
        }

        // Soft warning: an untagged sibling sub coexisting with a Subs/
        // folder that has language-tagged entries is almost always a
        // YTS-style duplicate of one of the tagged tracks. The composed
        // names don't actually collide, but the user probably wants to
        // know.
        let subsHasTaggedTrack = assets.contains { asset in
            asset.originalContainer != nil && asset.language != nil
        }
        if subsHasTaggedTrack {
            for i in assets.indices
            where assets[i].originalContainer == nil
                    && assets[i].language == nil
                    && assets[i].status != .failed
            {
                assets[i].warningReason =
                    "Untagged sibling — may duplicate a language-tagged Subs/ entry"
            }
        }

        return assets
    }

    /// Composes a target path for one subtitle file, resolving any naming
    /// collision against the shared allocator with a numeric `.N` suffix.
    /// Centralized here so the foldered and loose-video code paths share
    /// the descriptor-aware naming + collision logic.
    private static func buildAsset(
        sourcePath: String,
        sourceFilename: String,
        targetFolder: String,
        newStem: String,
        originalContainer: String?,
        allocator: inout UniqueTargetAllocator
    ) -> SubtitleAsset {
        let parsed = SubtitleClassifier.parse(filename: sourceFilename)
        let ext = (sourceFilename as NSString).pathExtension
        // Pre-existing `.N` collision suffix (from a prior rename pass)
        // is preserved through compose. Without this the planner would
        // see `<base>.en.srt` and `<base>.en.2.srt` as both targeting
        // `<base>.en.srt`, then alphabetical ordering ("2" < "s") would
        // make the `.2` file win the unsuffixed slot — the two files
        // swap on every apply.
        let preservedSuffix = SubtitleClassifier.extractNumericSuffix(filename: sourceFilename)
        let composedName = SubtitleClassifier.compose(
            base: newStem,
            lang: parsed.lang,
            forced: parsed.forced,
            sdh: parsed.sdh,
            descriptor: parsed.descriptor,
            numericSuffix: preservedSuffix,
            ext: ext
        )
        let proposed = (targetFolder as NSString).appendingPathComponent(composedName)
        let (finalPath, suffixed) = allocator.unique(proposed)
        return SubtitleAsset(
            path: sourcePath,
            newPath: finalPath,
            originalContainer: originalContainer,
            language: parsed.lang,
            isForced: parsed.forced,
            isSDH: parsed.sdh,
            descriptor: parsed.descriptor,
            collisionSuffix: suffixed
        )
    }

    /// Stateful allocator that hands out unique target paths. First caller
    /// gets the proposed path as-is; subsequent callers asking for the
    /// same path get `.2`, `.3`, … suffixed before the extension.
    private struct UniqueTargetAllocator {
        var assigned: Set<String> = []

        mutating func unique(_ proposed: String) -> (path: String, suffixed: Bool) {
            if !assigned.contains(proposed) {
                assigned.insert(proposed)
                return (proposed, false)
            }
            let dir = (proposed as NSString).deletingLastPathComponent
            let basename = (proposed as NSString).lastPathComponent
            let stem = (basename as NSString).deletingPathExtension
            let ext = (basename as NSString).pathExtension
            var n = 2
            while true {
                let nextName = ext.isEmpty ? "\(stem).\(n)" : "\(stem).\(n).\(ext)"
                let candidate = (dir as NSString).appendingPathComponent(nextName)
                if !assigned.contains(candidate) {
                    assigned.insert(candidate)
                    return (candidate, true)
                }
                n += 1
            }
        }
    }

    /// For loose top-level videos: filter the pre-scanned root subtitle
    /// index down to entries whose stem is either an exact match or starts
    /// with the video's stem *followed by a separator* (case-insensitive).
    /// The boundary check prevents `Movie.mkv` from wrongly claiming
    /// `MovieTwo.en.srt`. Subs/ subfolders are ignored here — at the scan
    /// root they can't be unambiguously associated with one video.
    private static func subtitlesForLooseVideo(
        videoStem: String,
        newFolder: String,
        newStem: String,
        candidates: [SubtitleScanEntry]
    ) -> [SubtitleAsset] {
        let prefix = videoStem.lowercased()
        let prefixCount = prefix.count
        let separators: Set<Character> = [".", "-", "_", " "]
        var assets: [SubtitleAsset] = []
        var allocator = UniqueTargetAllocator()
        // Loose siblings at the scan root go into `Subs/` inside the new
        // wrapper, same convention as foldered videos. The applySubtitles
        // safety net creates the `Subs/` folder on demand if it doesn't
        // already exist.
        let canonicalSubsFolder = (newFolder as NSString)
            .appendingPathComponent(SubtitleClassifier.canonicalFolderName)
        // Sorted so collision-suffix numbering is deterministic.
        let sorted = candidates.sorted(by: { $0.filename < $1.filename })
        for candidate in sorted {
            let candidateStem = (candidate.filename as NSString)
                .deletingPathExtension
                .lowercased()
            guard candidateStem.hasPrefix(prefix) else { continue }
            // Either exact match, or the next char after the prefix is a
            // recognized separator. Rejects "MovieTwo" matching "Movie".
            if candidateStem.count > prefixCount {
                let boundaryIdx = candidateStem.index(candidateStem.startIndex, offsetBy: prefixCount)
                guard separators.contains(candidateStem[boundaryIdx]) else { continue }
            }
            let asset = Self.buildAsset(
                sourcePath: candidate.path,
                sourceFilename: candidate.filename,
                targetFolder: canonicalSubsFolder,
                newStem: newStem,
                originalContainer: nil,
                allocator: &allocator
            )
            assets.append(asset)
        }
        return assets
    }

    private struct SubtitleScanEntry {
        let filename: String
        let path: String
    }

    /// Lists subtitle files directly in `directory`. When `includeSubfolders`
    /// is false, doesn't descend — used for both the scan-root index and
    /// the inside-of-a-Subs-folder enumeration (the caller drives whether
    /// to recurse into Subs/ separately).
    private static func scanForSubtitles(
        directory: String,
        includeSubfolders: Bool
    ) -> [SubtitleScanEntry] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [SubtitleScanEntry] = []
        for entry in entries {
            let path = (directory as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if includeSubfolders {
                    out.append(contentsOf: scanForSubtitles(directory: path, includeSubfolders: true))
                }
                continue
            }
            let ext = (entry as NSString).pathExtension
            if SubtitleClassifier.isSubtitleExtension(ext) {
                out.append(SubtitleScanEntry(filename: entry, path: path))
            }
        }
        return out
    }

    /// Path relative to `rootStd` when nested inside it, otherwise the raw
    /// path. Used for table cells so paths stay readable.
    private static func displayPath(_ path: String, rootStd: String) -> String {
        let pathStd = URL(fileURLWithPath: path).standardizedFileURL.path
        let trimmedRoot = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        if pathStd.hasPrefix(trimmedRoot) {
            return String(pathStd.dropFirst(trimmedRoot.count))
        }
        return path
    }
}
