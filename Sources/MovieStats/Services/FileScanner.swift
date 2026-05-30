import Foundation

/// A lightweight value describing one file found on disk, before it is
/// persisted or shown in the UI.
struct ScannedFile: Identifiable, Hashable, Sendable {
    let filename: String
    let path: String
    let size: Int64

    var id: String { path }
}

/// Shared, recursive directory walk used by the movie and image scanners.
///
/// Pure and side-effect free: it only reads the filesystem and returns
/// values, so it is safe to run off the main actor.
enum FileScanner {
    /// Returns every regular file under `url` (including subfolders) whose
    /// extension is in `extensions` (compared case-insensitively).
    static func scan(directory url: URL, extensions: Set<String>) -> [ScannedFile] {
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
            guard extensions.contains(fileURL.pathExtension.lowercased()) else { continue }

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
