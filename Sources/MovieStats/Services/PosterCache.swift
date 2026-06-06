import AppKit
import Foundation

/// On-disk cache of TMDB poster artwork. We store one image per TMDB ID under
/// Application Support so we don't re-download every time the detail popup
/// opens. The matcher writes here at confirm time; the detail view reads.
enum PosterCache {
    /// `~/Library/Application Support/MovieStats/posters` — created lazily on
    /// first save.
    static func directoryURL() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support
            .appendingPathComponent("MovieStats", isDirectory: true)
            .appendingPathComponent("posters", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// File URL for a given TMDB id. Suffix is fixed `.jpg` because TMDB
    /// always serves JPEGs at /t/p/.
    static func posterURL(forTMDBID id: Int) -> URL? {
        directoryURL()?.appendingPathComponent("\(id).jpg")
    }

    /// True iff a poster has already been cached for this TMDB id.
    static func hasPoster(forTMDBID id: Int) -> Bool {
        guard let url = posterURL(forTMDBID: id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Saves the given image bytes to disk for `tmdbID`. No-ops on nil/empty.
    static func savePoster(_ data: Data?, forTMDBID id: Int) {
        guard let data, !data.isEmpty, let url = posterURL(forTMDBID: id) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads a cached poster back as an `NSImage`. Returns nil if absent.
    static func loadPoster(forTMDBID id: Int) -> NSImage? {
        guard let url = posterURL(forTMDBID: id),
              FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    /// Downloads a poster for `tmdbID` from TMDB and writes it locally, but
    /// only if the path is non-nil and we don't already have it. Used by the
    /// matcher's confirm step.
    @discardableResult
    static func downloadIfNeeded(tmdbID: Int, posterPath: String?) async -> Bool {
        guard let posterPath, !posterPath.isEmpty else { return false }
        if hasPoster(forTMDBID: tmdbID) { return true }
        do {
            let data = try await TMDBService.downloadImage(path: posterPath)
            savePoster(data, forTMDBID: tmdbID)
            return data != nil
        } catch {
            return false
        }
    }
}
