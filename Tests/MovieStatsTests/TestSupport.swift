import Foundation

/// A throwaway directory under the system temp location. Create files into
/// it, then call `cleanup()` (or rely on it being unique per test) so tests
/// never touch the real library or each other.
final class TempDir {
    let url: URL
    private let fm = FileManager.default

    init() {
        // Root scratch under the package's .build dir, NOT the system temp.
        // macOS temp lives under /var/folders (a symlink to /private/var);
        // DirectoryScanner normalizes its root via standardizedFileURL
        // (/private/var → /var) while FileManager's enumerator yields the
        // resolved /private/var, so a temp-dir root can never satisfy the
        // scanner's own prefix check. A path under /Users/... (.build) has no
        // such symlink, matching production roots like /Volumes/Media.
        let root = TempDir.packageRoot()
        url = root.appendingPathComponent(
            ".build/test-scratch/MovieStatsTests-\(UUID().uuidString)", isDirectory: true
        )
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Package root, derived from this source file's location
    /// (`<root>/Tests/MovieStatsTests/TestSupport.swift`) so it's independent
    /// of the working directory `swift test` happens to run in.
    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MovieStatsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    deinit { try? fm.removeItem(at: url) }

    var path: String { url.path }

    /// Creates a file (with intermediate folders) at `relative`, returns its
    /// absolute path.
    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 8) -> String {
        let fileURL = url.appendingPathComponent(relative)
        try? fm.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        fm.createFile(atPath: fileURL.path, contents: Data(repeating: 0, count: bytes))
        return fileURL.path
    }

    func makeDir(_ relative: String) {
        try? fm.createDirectory(
            at: url.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent(relative).path)
    }

    func absolute(_ relative: String) -> String {
        url.appendingPathComponent(relative).path
    }
}
