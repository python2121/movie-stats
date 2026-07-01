import Foundation
import Observation

/// App-level state behind the Smart Import toolbar button. Owns the watch
/// directory and a background poll that detects confidently-importable videos
/// so the toolbar button can light up blue without the user lifting a finger.
///
/// Detection is delegated to `SmartImportScanner` (network + filesystem, no
/// side effects). This object only holds the watch path + the latest result
/// and schedules the periodic re-scan. The actual import work lives in
/// `SmartImportModel`, created per-window.
@MainActor
@Observable
final class SmartImportMonitor {
    private static let watchKey = "smartImportWatchDirectory"
    /// How often the background scan re-checks the watch directory while the
    /// app is running. One hour, per the feature spec.
    private static let interval: TimeInterval = 3600

    /// The staging directory we watch (e.g. a `/complete`-style download
    /// folder). UserDefaults-backed so it survives restarts — the app is
    /// unsandboxed, so no security-scoped bookmark is needed (same rationale
    /// as `AppModel.directoryPath`, CLAUDE.md §6.16).
    var watchDirectory: String {
        didSet { UserDefaults.standard.set(watchDirectory, forKey: Self.watchKey) }
    }

    /// Number of videos in the watch dir that confidently auto-match TMDB as
    /// of the last scan. Drives the blue toolbar highlight.
    private(set) var pendingMatchCount = 0
    /// TMDB lookups that errored during the last background scan. Non-zero
    /// means `pendingMatchCount` may be an undercount (network trouble, rate
    /// limit) — surfaced in the toolbar so "no matches" isn't mistaken for
    /// "nothing on TMDB".
    private(set) var lastScanFailureCount = 0
    private(set) var lastScanAt: Date?
    private(set) var isScanning = false
    /// Set when `scanNow` is called while a scan is already running, so the
    /// in-flight scan re-runs once more when it finishes. Guarantees the
    /// post-import refresh (which may collide with the hourly poll) is never
    /// dropped — otherwise the blue button could keep a stale count until the
    /// next hourly tick.
    private var rescanRequested = false

    var hasWatchDirectory: Bool { !watchDirectory.isEmpty }
    /// True when the last scan found something worth importing — the toolbar
    /// button renders blue while this holds.
    var hasPending: Bool { pendingMatchCount > 0 }

    private var pollTask: Task<Void, Never>?

    init() {
        watchDirectory = UserDefaults.standard.string(forKey: Self.watchKey) ?? ""
    }

    /// Points the monitor at a new watch directory and immediately re-scans.
    func setWatchDirectory(_ path: String) {
        watchDirectory = path
        Task { await scanNow() }
    }

    /// Lets the Smart Import window push its authoritative match count back to
    /// the toolbar — its `prepare()` does a full, fresh scan, so the button
    /// should agree with what the window just found without waiting for the
    /// next background tick.
    func updatePendingCount(_ count: Int) {
        pendingMatchCount = count
        // The window's full match pass is authoritative — clear any stale
        // incomplete-scan flag from the background poll.
        lastScanFailureCount = 0
        lastScanAt = Date()
    }

    /// Starts the periodic background scan (no-op if already running). Kicks an
    /// immediate scan, then re-scans every `interval`. We use a sleeping Task
    /// rather than a `Timer` so the loop inherits this object's main-actor
    /// isolation cleanly under Swift 6 strict concurrency.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.scanNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                if Task.isCancelled { break }
                await self?.scanNow()
            }
        }
    }

    /// Runs one detection pass (coalescing concurrent requests). Refreshed on
    /// launch, after the watch dir changes, and after an import completes — so
    /// the blue highlight clears once the watch dir is drained of matches.
    func scanNow() async {
        guard hasWatchDirectory else { return }
        // A scan is already running — ask it to repeat with the latest state
        // rather than dropping this request.
        if isScanning {
            rescanRequested = true
            return
        }
        isScanning = true
        repeat {
            rescanRequested = false
            let outcome = await SmartImportScanner.confidentMatches(in: watchDirectory)
            pendingMatchCount = outcome.matchedPaths.count
            lastScanFailureCount = outcome.searchFailures
            lastScanAt = Date()
        } while rescanRequested
        isScanning = false
    }
}
