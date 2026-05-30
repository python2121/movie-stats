import Foundation

/// A lightweight value describing one file found on disk, before it is
/// persisted into the database.
struct ScannedFile: Sendable {
    let filename: String
    let path: String
    let size: Int64
}

/// Recursively walks a directory and returns every movie file it finds,
/// including those nested in subfolders.
///
/// Pure and side-effect free: it only reads the filesystem and returns
/// values, so it is safe to run off the main actor.
enum DirectoryScanner {
    /// File extensions we consider to be "movies". Lowercased for comparison.
    static let movieExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "wmv",
        "flv", "webm", "mpg", "mpeg", "m2ts", "ts", "vob", "ogv",
    ]

    static func scan(directory url: URL) -> [ScannedFile] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [ScannedFile] = []
        for case let fileURL as URL in enumerator {
            guard movieExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            results.append(
                ScannedFile(
                    filename: fileURL.lastPathComponent,
                    path: fileURL.path,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return results
    }
}
