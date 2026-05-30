import Foundation

/// Recursively finds movie files in a directory, including subfolders.
enum DirectoryScanner {
    /// File extensions we consider to be "movies". Lowercased for comparison.
    static let movieExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "wmv",
        "flv", "webm", "mpg", "mpeg", "m2ts", "ts", "vob", "ogv",
    ]

    static func scan(directory url: URL) -> [ScannedFile] {
        FileScanner.scan(directory: url, extensions: movieExtensions)
    }
}
