import Foundation

/// Recursively finds movie files in a directory, including subfolders.
enum DirectoryScanner {
    /// File extensions we consider to be "movies". Lowercased for comparison.
    static let movieExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "wmv",
        "flv", "webm", "mpg", "mpeg", "m2ts", "ts", "vob", "ogv",
    ]

    /// Plex/Jellyfin-recognized extras subfolder names. A video nested
    /// underneath any of these (anywhere between the scan root and the
    /// file) is bonus content, not a main movie — gets filtered out
    /// of the library catalog so it doesn't end up in `movies`
    /// alongside the matched titles. The `extras` table still tracks
    /// them by their full path.
    ///
    /// Match is case-insensitive on the whole path component, so
    /// `Other/foo.mkv` is an extra but a movie literally titled
    /// `The Others (2001) {tmdb-...}` (wrapper basename is the whole
    /// canonical title, not "Other") doesn't false-positive.
    static let extrasFolderNames: Set<String> = [
        "behind the scenes",
        "deleted scenes",
        "featurettes",
        "interviews",
        "scenes",
        "shorts",
        "trailers",
        "other",
    ]

    static func scan(directory url: URL) -> [ScannedFile] {
        let all = FileScanner.scan(directory: url, extensions: movieExtensions)
        let rootPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return all.filter { file in
            guard file.path.hasPrefix(rootPrefix) else { return true }
            let relative = String(file.path.dropFirst(rootPrefix.count))
            // Drop the filename itself — only intermediate folder
            // components are relevant to the extras check.
            let folders = relative.split(separator: "/").dropLast()
            return !folders.contains { extrasFolderNames.contains($0.lowercased()) }
        }
    }
}
