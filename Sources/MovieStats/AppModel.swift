import AppKit
import Foundation
import Observation
import UserNotifications

/// The app's single source of truth. Owns the database, the in-memory list of
/// movies, the directory scan, and the per-file metadata probe. Views observe
/// this and stay declarative.
@MainActor
@Observable
final class AppModel {
    /// Files at or above this size count as "large". 20 GiB.
    static let largeFileThreshold: Int64 = 20 * 1024 * 1024 * 1024

    /// Number of ffprobe processes allowed to run at once during a probe pass.
    /// ffprobe just reads headers so it's mostly I/O bound; small N keeps
    /// network volumes from thrashing.
    private static let probeConcurrency = 6

    private(set) var movies: [MovieFile] = []
    /// In-memory snapshot of every row in the `extras` table. Keyed
    /// by TMDB id in the views (each library row pulls its extras
    /// out by parent's `tmdbId`), so a single load powers both the
    /// detail-sheet's Extras section and the library row's Play
    /// menu without an N-rows × per-row DB hit on every render.
    private(set) var extras: [ExtraFile] = []
    private(set) var isScanning = false
    var lastError: String?

    // MARK: - Probe state (UI-observable)

    private(set) var isProbing = false
    private(set) var probedCount = 0
    private(set) var probeTotal = 0
    /// Set by the scan sheet's Cancel button. In-flight ffprobe processes
    /// finish; nothing new is scheduled. Unprobed rows keep probed_at NULL,
    /// so the next Rescan resumes exactly where this one stopped.
    private(set) var cancelRequested = false
    /// Path of the most recently kicked-off probe — drives the live filename
    /// shown in the scanning progress sheet.
    private(set) var currentProbePath: String?

    /// True when an `ffprobe` binary is available (bundled or via Homebrew).
    /// Used to surface a hint banner if it isn't.
    var ffprobeAvailable: Bool { MediaProbe.locateBinary() != nil }

    /// The directory the user last opened. Persisted so a rescan after restart
    /// targets the same folder.
    var directoryPath: String {
        didSet { UserDefaults.standard.set(directoryPath, forKey: Self.directoryKey) }
    }

    /// Exposed for the TMDB matcher window so it can read/write the
    /// tmdb_movies table and per-file matches directly.
    let store: MovieStore?

    /// Pulls a fresh `[MovieFile]` snapshot from the database. Used after the
    /// matcher writes TMDB ids so the checkmark column refreshes.
    func reloadFromStore() {
        guard let store else { return }
        if let updated = try? store.allMovies() {
            movies = updated
        }
        if let updated = try? store.allExtras() {
            extras = updated
        }
    }

    /// Permanently deletes the given library copies — for each one, the
    /// video file, its sidecar subtitles, and the wrapping folder when
    /// the folder belongs to that movie alone — then reloads the
    /// in-memory snapshot so observers see the post-deletion library
    /// immediately. Returns a list of per-file failure messages for
    /// items that couldn't be removed (caller decides how to surface
    /// them).
    ///
    /// Shared by:
    ///   - `ImportSession.performReplacements` — when the user checked
    ///     Replace at the Match step of the import wizard.
    ///   - `MatcherView`'s standalone-Confirm dialog — when the user
    ///     checked Replace while matching unmatched library files.
    ///
    /// Permanent deletes, per the app's no-Trash design. Caller is
    /// responsible for prompting + confirmation.
    func deleteLibraryCopies(_ targets: [MovieFile]) async -> [String] {
        guard let store, hasDirectory else { return [] }
        let fm = FileManager.default
        let libraryRoot = URL(fileURLWithPath: directoryPath).standardizedFileURL.path
        var failures: [String] = []

        for existing in targets {
            let parent = URL(fileURLWithPath: existing.path).standardizedFileURL
                .deletingLastPathComponent().path
            // Wrapper-folder delete only when the folder is *inside*
            // the library root, isn't the library root itself, and no
            // other library movie shares it. Multi-quality wrappers
            // hold two videos under the same canonical name; deleting
            // the wrapper there would nuke the sibling too.
            let wrapperDeletable = parent != libraryRoot
                && parent.hasPrefix(libraryRoot + "/")
                && !movies.contains {
                    $0.path != existing.path && $0.path.hasPrefix(parent + "/")
                }
            do {
                if wrapperDeletable {
                    try fm.removeItem(atPath: parent)
                    // The wrapper carried any `Subs/` folder + its
                    // sidecar files with it on the way out. The DB
                    // rows attributed to this movie need to follow —
                    // the standalone matcher's Replace flow doesn't
                    // trigger a full rescan afterwards (only a
                    // reloadFromStore), so without this the
                    // subtitle_files table would keep rows pointing
                    // at gone paths until the next user-initiated
                    // Rescan rebuilt the table.
                    let subs = (try? store.subtitleFiles(forMoviePath: existing.path)) ?? []
                    for sub in subs {
                        try? store.deleteSubtitleFile(path: sub.path)
                    }
                } else {
                    try fm.removeItem(atPath: existing.path)
                    let subs = (try? store.subtitleFiles(forMoviePath: existing.path)) ?? []
                    for sub in subs {
                        try? fm.removeItem(atPath: sub.path)
                        try? store.deleteSubtitleFile(path: sub.path)
                    }
                }
                try store.deleteMovie(path: existing.path)
            } catch {
                failures.append("\(existing.filename): \(error.localizedDescription)")
            }
        }

        reloadFromStore()
        return failures
    }

    private static let directoryKey = "selectedDirectoryPath"
    private static let recentsKey = "recentDirectoryPaths"

    /// Most-recently-opened library roots, newest first. Drives the
    /// Library → Open Recent menu.
    private(set) var recentDirectories: [String]

    init() {
        directoryPath = UserDefaults.standard.string(forKey: Self.directoryKey) ?? ""
        recentDirectories = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []

        // Open the store once. If opening or the initial load fails, surface
        // the error and run without a backing store.
        let openedStore: MovieStore?
        do {
            let store = try MovieStore()
            // Load the previous scan straight from disk — no rescan needed.
            movies = try store.allMovies()
            extras = (try? store.allExtras()) ?? []
            openedStore = store
        } catch {
            openedStore = nil
            lastError = "\(error)"
        }
        self.store = openedStore
    }

    // MARK: - Derived stats

    var movieCount: Int { movies.count }

    var largeMovieCount: Int {
        movies.filter { $0.size >= Self.largeFileThreshold }.count
    }

    var unwatchedCount: Int {
        movies.filter { $0.watchedAt == nil }.count
    }

    var totalSize: Int64 {
        movies.reduce(0) { $0 + $1.size }
    }

    /// Movies ordered largest first, for the ranked list in the main window.
    var moviesBySize: [MovieFile] {
        movies.sorted { $0.size > $1.size }
    }

    var hasDirectory: Bool { !directoryPath.isEmpty }

    // MARK: - Actions

    /// Shows the standard open panel and points the library at the chosen
    /// directory. Used by the toolbar button and the Library → Open Directory
    /// menu item.
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a directory to scan for movies"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url.path)
    }

    /// Points the library at a new root, records it in the recents list, and
    /// kicks off a scan.
    func setDirectory(_ path: String) {
        directoryPath = path
        var recents = recentDirectories.filter { $0 != path }
        recents.insert(path, at: 0)
        recentDirectories = Array(recents.prefix(8))
        UserDefaults.standard.set(recentDirectories, forKey: Self.recentsKey)
        Task { await rescan() }
    }

    func clearRecentDirectories() {
        recentDirectories = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    func setWatched(_ movie: MovieFile, watched: Bool) {
        let date = watched ? Date() : nil
        do {
            try store?.setWatched(path: movie.path, watchedAt: date)
        } catch {
            lastError = "\(error)"
            return
        }
        if let idx = movies.firstIndex(where: { $0.path == movie.path }) {
            movies[idx].watchedAt = date
        }
    }

    func setPersonalRating(_ movie: MovieFile, rating: Int?) {
        do {
            try store?.setPersonalRating(path: movie.path, rating: rating)
        } catch {
            lastError = "\(error)"
            return
        }
        if let idx = movies.firstIndex(where: { $0.path == movie.path }) {
            movies[idx].personalRating = rating
        }
    }

    /// Rescans the current directory: crawls the filesystem off the main
    /// actor, reconciles the database (new files added, missing files
    /// removed, existing files keep their probed metadata), then starts a
    /// probing pass for any rows still missing metadata.
    func rescan() async {
        guard let store, hasDirectory, !isScanning else { return }

        isScanning = true
        lastError = nil
        cancelRequested = false
        // Long scans over SMB die if the Mac idle-sleeps mid-walk.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Scanning movie library"
        )
        defer {
            isScanning = false
            ProcessInfo.processInfo.endActivity(activity)
            notifyScanFinished()
        }

        let url = URL(fileURLWithPath: directoryPath)
        let (scanned, subtitles) = await Task.detached(priority: .userInitiated) {
            let videos = DirectoryScanner.scan(directory: url)
            let subs = SubtitleScanner.scan(directory: url, videos: videos)
            return (videos, subs)
        }.value

        do {
            try store.replaceAll(scanned)
            try store.replaceAllSubtitleFiles(subtitles)
            movies = try store.allMovies()
            extras = (try? store.allExtras()) ?? []
        } catch {
            lastError = "\(error)"
            return
        }

        guard !cancelRequested else { return }
        await probeMissing()
    }

    func cancelScan() {
        cancelRequested = true
    }

    /// Force a re-read of every file's metadata. Clears probed_at then runs
    /// the same path as a normal probe pass.
    func reprobeAll() async {
        guard let store else { return }
        cancelRequested = false
        do {
            try store.clearAllMetadata()
            movies = try store.allMovies()
            extras = (try? store.allExtras()) ?? []
        } catch {
            lastError = "\(error)"
            return
        }
        await probeMissing()
    }

    /// Probes every row whose `probed_at` is still NULL, capped at
    /// `probeConcurrency` parallel ffprobe processes. Updates the in-memory
    /// model as each file finishes so chips appear progressively in the UI.
    private func probeMissing() async {
        guard let store else { return }
        let pending: [(path: String, size: Int64)]
        do {
            pending = try store.filesMissingMetadata()
        } catch {
            lastError = "\(error)"
            return
        }
        guard !pending.isEmpty else { return }

        probedCount = 0
        probeTotal = pending.count
        currentProbePath = pending.first?.path
        isProbing = true
        defer {
            isProbing = false
            probedCount = 0
            probeTotal = 0
            currentProbePath = nil
        }

        var nextIndex = 0
        await withTaskGroup(of: ProbeOutcome.self) { group in
            // Seed the first batch.
            while nextIndex < min(Self.probeConcurrency, pending.count) {
                let item = pending[nextIndex]
                nextIndex += 1
                currentProbePath = item.path
                group.addTask {
                    let info = await MediaProbe.probe(path: item.path)
                    return ProbeOutcome(path: item.path, size: item.size, info: info)
                }
            }

            while let outcome = await group.next() {
                apply(outcome: outcome, store: store)
                probedCount += 1

                if nextIndex < pending.count, !cancelRequested {
                    let item = pending[nextIndex]
                    nextIndex += 1
                    currentProbePath = item.path
                    group.addTask {
                        let info = await MediaProbe.probe(path: item.path)
                        return ProbeOutcome(path: item.path, size: item.size, info: info)
                    }
                }
            }
        }
    }

    /// Persists a single probe result and patches the in-memory movie in
    /// place so the row in the UI updates immediately.
    private func apply(outcome: ProbeOutcome, store: MovieStore) {
        guard let info = outcome.info else { return }
        let movieType = MovieClassifier.classify(
            width: info.width,
            height: info.height,
            codec: info.videoCodec,
            size: outcome.size
        ).rawValue

        do {
            try store.updateMetadata(path: outcome.path, info: info, movieType: movieType)
        } catch {
            lastError = "\(error)"
            return
        }

        if let idx = movies.firstIndex(where: { $0.path == outcome.path }) {
            var m = movies[idx]
            m.width = info.width
            m.height = info.height
            m.durationSeconds = info.durationSeconds
            m.bitrate = info.bitrate
            m.videoCodec = info.videoCodec
            m.container = info.container
            m.pixFmt = info.pixFmt
            m.is10Bit = info.is10Bit
            m.hdrFormat = info.hdrFormat
            m.hasDolbyVision = info.hasDolbyVision
            m.videoTracks = info.videoTracks
            m.audioTracks = info.audioTracks
            m.subtitleTracks = info.subtitleTracks
            m.audioCodecs = info.audioCodecs
            m.audioChannels = info.audioChannels
            m.audioLanguages = info.audioLanguages
            m.subtitleCodecs = info.subtitleCodecs
            m.subtitleLanguages = info.subtitleLanguages
            m.movieType = movieType
            m.probedAt = Date()
            movies[idx] = m
        }
    }

    private struct ProbeOutcome: Sendable {
        let path: String
        let size: Int64
        let info: MediaInfo?
    }

    /// Posts a "scan finished" user notification, but only when the app is
    /// in the background — if the user is looking at the window they can
    /// already see the result. Guarded to the bundled .app: the
    /// notification center API aborts in a bare `swift run` binary.
    private func notifyScanFinished() {
        guard Bundle.main.bundleIdentifier != nil,
              !NSApplication.shared.isActive
        else { return }
        let count = movieCount
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Library scan finished"
            content.body = "\(count) movies indexed."
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            ))
        }
    }
}
