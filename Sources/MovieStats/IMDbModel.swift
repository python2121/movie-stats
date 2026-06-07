import Foundation

/// Backs the "IMDb Ratings" window. Holds the dataset-refresh state machine
/// and the persisted metadata (when the user last downloaded + how many
/// ratings landed). All work runs through `refresh()` — download, gunzip,
/// parse, bulk-import — and the model updates `state` at each phase so the
/// UI can paint a meaningful status line.
@MainActor
@Observable
final class IMDbModel {
    enum State: Equatable {
        case idle
        case downloading
        case decompressing
        case parsing
        case importing(count: Int)
        case completed
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Pulled from `imdb_metadata` on init + after every successful refresh.
    private(set) var lastDownloadedAt: Date?
    private(set) var entryCount: Int = 0

    private let appModel: AppModel

    init(appModel: AppModel) {
        self.appModel = appModel
        loadMetadata()
    }

    /// True iff we're currently mid-refresh. The window disables the
    /// Refresh button while this is true.
    var isWorking: Bool {
        switch state {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }

    var hasData: Bool { entryCount > 0 }

    /// Pulls the persisted metadata into the observable fields. Called on
    /// init and again after a successful refresh so the UI reflects fresh
    /// counts immediately.
    func loadMetadata() {
        let meta = appModel.store?.imdbMetadata() ?? (lastDownloadedAt: nil, entryCount: 0)
        lastDownloadedAt = meta.lastDownloadedAt
        entryCount = meta.entryCount
    }

    /// Runs the full refresh pipeline. Each phase updates `state` so the
    /// UI can show what's happening. On success: persists, reloads metadata,
    /// nudges AppModel to re-read every movie row so the joined IMDb
    /// columns refresh in the main library.
    func refresh() async {
        guard !isWorking, let store = appModel.store else { return }
        state = .downloading
        var tempGz: URL?
        var tempTsv: URL?
        defer {
            if let tempGz, FileManager.default.fileExists(atPath: tempGz.path) {
                try? FileManager.default.removeItem(at: tempGz)
            }
            if let tempTsv, FileManager.default.fileExists(atPath: tempTsv.path) {
                try? FileManager.default.removeItem(at: tempTsv)
            }
        }

        do {
            let gz = try await IMDbDatasetService.downloadRatings()
            tempGz = gz

            state = .decompressing
            let tsv = try await IMDbDatasetService.decompress(gz)
            tempTsv = tsv
            // `gunzip -f` consumes the .gz, so no cleanup needed for it.
            tempGz = nil

            state = .parsing
            let ratings = try await IMDbDatasetService.parseRatings(tsv)

            state = .importing(count: ratings.count)
            // SQLite bulk insert with prepared statement reuse — runs on the
            // main actor because MovieStore isn't Sendable. ~2-3s for 1.4M
            // rows; the UI freezes briefly but the status text gives context.
            try store.replaceAllIMDbRatings(
                ratings.map { ($0.imdbID, $0.rating, $0.votes) }
            )

            loadMetadata()
            appModel.reloadFromStore()
            state = .completed
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
