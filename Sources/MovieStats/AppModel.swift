import Foundation
import Observation

/// The app's single source of truth. Owns the database, the in-memory list of
/// movies, and the scanning workflow. Views observe this and stay declarative.
@MainActor
@Observable
final class AppModel {
    /// Files at or above this size count as "large". 20 GiB.
    static let largeFileThreshold: Int64 = 20 * 1024 * 1024 * 1024

    private(set) var movies: [MovieFile] = []
    private(set) var isScanning = false
    var lastError: String?

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
    /// actor, replaces the stored snapshot, then refreshes the in-memory list.
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
        }
    }
}
