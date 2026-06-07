import Foundation

/// Pulls IMDb's bulk ratings dataset (`title.ratings.tsv.gz`) and shapes it
/// into rows the `MovieStore` can write. Three steps:
///
///   1. Download the gzipped TSV (`~10 MB`) to a temp file.
///   2. Decompress via the system `gunzip` (Apple's `Compression` framework
///      handles raw zlib but not the gzip wrapper; shelling out is cleaner).
///   3. Parse the TSV — header `tconst\taverageRating\tnumVotes` — skipping
///      malformed lines.
///
/// The user invokes a refresh from the IMDb window; this enum has no state
/// of its own.
enum IMDbDatasetService {
    /// Official IMDb-published dataset. No API key, no auth, no rate limit.
    /// Released under IMDb's non-commercial license; fine for personal apps.
    static let ratingsURL = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!

    struct Rating: Sendable {
        let imdbID: String
        let rating: Double
        let votes: Int
    }

    enum DatasetError: LocalizedError {
        case decompressFailed(Int32)
        case decompressedFileMissing(String)

        var errorDescription: String? {
            switch self {
            case .decompressFailed(let code):
                return "gunzip failed with status \(code)"
            case .decompressedFileMissing(let path):
                return "Decompressed file missing at \(path)"
            }
        }
    }

    /// Downloads the gzipped ratings dataset to a temp path and returns
    /// the local URL. The caller is responsible for cleaning up.
    static func downloadRatings() async throws -> URL {
        let session = URLSession.shared
        let (downloadedURL, _) = try await session.download(from: ratingsURL)
        // `download(from:)` returns a temp file that the system may purge
        // out from under us — move it somewhere we control.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("imdb_ratings_\(UUID().uuidString).tsv.gz")
        try FileManager.default.moveItem(at: downloadedURL, to: target)
        return target
    }

    /// Runs `/usr/bin/gunzip` on the given `.gz`, which decompresses in
    /// place (removes the .gz, leaves a same-named file without it).
    /// Returns the path to the decompressed file. Runs on a detached
    /// task so it doesn't block the MainActor.
    static func decompress(_ gzURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let outURL = gzURL.deletingPathExtension()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            process.arguments = ["-f", gzURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DatasetError.decompressFailed(process.terminationStatus)
            }
            guard FileManager.default.fileExists(atPath: outURL.path) else {
                throw DatasetError.decompressedFileMissing(outURL.path)
            }
            return outURL
        }.value
    }

    /// Parses the decompressed TSV into a `[Rating]` array. Skips the
    /// header row and any malformed lines. Runs on a detached task.
    static func parseRatings(_ tsvURL: URL) async throws -> [Rating] {
        try await Task.detached(priority: .userInitiated) {
            let content = try String(contentsOf: tsvURL, encoding: .utf8)
            var ratings: [Rating] = []
            ratings.reserveCapacity(1_500_000)
            var sawHeader = false
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                if !sawHeader {
                    sawHeader = true
                    continue
                }
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3,
                      let rating = Double(parts[1]),
                      let votes = Int(parts[2])
                else { continue }
                ratings.append(Rating(
                    imdbID: String(parts[0]),
                    rating: rating,
                    votes: votes
                ))
            }
            return ratings
        }.value
    }
}
