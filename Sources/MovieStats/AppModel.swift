import Foundation
import Observation

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
    private(set) var isScanning = false
    var lastError: String?

    // MARK: - Probe state (UI-observable)

    private(set) var isProbing = false
    private(set) var probedCount = 0
    private(set) var probeTotal = 0
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

    private let store: MovieStore?
    private static let directoryKey = "selectedDirectoryPath"

    init() {
        directoryPath = UserDefaults.standard.string(forKey: Self.directoryKey) ?? ""

        // Open the store once. If opening or the initial load fails, surface
        // the error and run without a backing store.
        let openedStore: MovieStore?
        do {
            let store = try MovieStore()
            // Load the previous scan straight from disk — no rescan needed.
            movies = try store.allMovies()
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

    var totalSize: Int64 {
        movies.reduce(0) { $0 + $1.size }
    }

    /// Movies ordered largest first, for the ranked list in the main window.
    var moviesBySize: [MovieFile] {
        movies.sorted { $0.size > $1.size }
    }

    var hasDirectory: Bool { !directoryPath.isEmpty }

    // MARK: - Actions

    /// Rescans the current directory: crawls the filesystem off the main
    /// actor, reconciles the database (new files added, missing files
    /// removed, existing files keep their probed metadata), then starts a
    /// probing pass for any rows still missing metadata.
    func rescan() async {
        guard let store, hasDirectory, !isScanning else { return }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let url = URL(fileURLWithPath: directoryPath)
        let scanned = await Task.detached(priority: .userInitiated) {
            DirectoryScanner.scan(directory: url)
        }.value

        do {
            try store.replaceAll(scanned)
            movies = try store.allMovies()
        } catch {
            lastError = "\(error)"
            return
        }

        await probeMissing()
    }

    /// Force a re-read of every file's metadata. Clears probed_at then runs
    /// the same path as a normal probe pass.
    func reprobeAll() async {
        guard let store else { return }
        do {
            try store.clearAllMetadata()
            movies = try store.allMovies()
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

                if nextIndex < pending.count {
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
}
