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
    private(set) var tmdbMatches: [String: (tmdbID: Int, confirmedYear: Int?)] = [:]

    /// Where we are in the wizard.
    var currentStep: Step = .pickDirectory

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

    func setTMDBMatch(forPath path: String, tmdbID: Int?, confirmedYear: Int?) throws {
        guard let idx = movies.firstIndex(where: { $0.path == path }) else { return }
        movies[idx].tmdbId = tmdbID
        movies[idx].confirmedYear = confirmedYear
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
            tmdbMatches[path] = (tmdbID, confirmedYear)
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
    }

    // MARK: - Step 0: pick + scan

    /// Replaces the current source directory and scans it for video
    /// files. Clears any prior import state. Safe to call again to
    /// switch to a different source.
    func setSourceDirectory(_ path: String) async {
        sourceDirectory = path
        movies = []
        tmdbMatches.removeAll()
        currentStep = .pickDirectory
        lastError = nil
        await rescan()
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

    // MARK: - Step 7: Move to Library

    /// Final action. For each *top-level* item in the source directory
    /// (typically a renamed wrapper folder like
    /// `<title> (<year>) {tmdb-N}` after the rename step), moves the
    /// item into the live library directory, then triggers a rescan +
    /// re-applies the TMDB matches for the moved files.
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

        let fm = FileManager.default
        let topLevelItems: [String]
        do {
            topLevelItems = try fm.contentsOfDirectory(atPath: sourceDirectory).sorted()
        } catch {
            lastError = "Couldn't read source directory: \(error.localizedDescription)"
            return
        }

        // Track success: post-move path of each in-memory movie so we
        // can re-apply TMDB matches after the rescan.
        var rekeyedMatches: [String: (tmdbID: Int, confirmedYear: Int?)] = [:]
        var failures: [String] = []

        for item in topLevelItems {
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

        // Pick up the moved files in the live library, then re-apply
        // the TMDB matches by path.
        await appModel.rescan()
        if let store = appModel.store {
            for (path, match) in rekeyedMatches {
                try? store.setTMDBMatch(
                    forPath: path,
                    tmdbID: match.tmdbID,
                    confirmedYear: match.confirmedYear
                )
            }
            appModel.reloadFromStore()
        }

        // Reset our in-memory state and signal completion.
        let movedCount = rekeyedMatches.count
        movies = []
        tmdbMatches.removeAll()
        sourceDirectory = ""
        currentStep = .done
        if movedCount > 0, lastError == nil {
            lastError = nil
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
