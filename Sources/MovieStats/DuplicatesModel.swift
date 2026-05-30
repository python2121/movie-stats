import Foundation

/// A top-level folder under the scan root that contains more than one video
/// file (counting videos nested in any subfolder beneath it).
struct DuplicateGroup: Identifiable, Hashable {
    /// Full path of the top-level folder, e.g. "/media/videofolder".
    let directory: String
    /// The folder's display name, e.g. "videofolder".
    let name: String
    /// Every video found anywhere beneath `directory`, largest first.
    let files: [ScannedFile]

    var id: String { directory }
}

/// Backs the "Multiple Videos per Folder" window: scans the root for videos,
/// groups them by their top-level subfolder, and surfaces folders holding more
/// than one. Selected files can be permanently deleted with progress.
@MainActor
@Observable
final class DuplicatesModel {
    private(set) var groups: [DuplicateGroup] = []
    private(set) var isScanning = false
    private(set) var isDeleting = false

    /// 0...1 progress for the current delete operation.
    private(set) var deleteProgress = 0.0

    /// Paths of the rows currently checked.
    var selection: Set<String> = []

    var lastError: String?

    var hasSelection: Bool { !selection.isEmpty }

    /// Total number of videos shown across all groups.
    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    var allSelected: Bool {
        fileCount > 0 && selection.count == fileCount
    }

    /// Checks every listed video if not all are selected, otherwise clears the
    /// selection.
    func toggleSelectAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(groups.flatMap { $0.files.map(\.path) })
        }
    }

    /// Scans `directory` for videos and rebuilds the grouped list. Prunes any
    /// checked rows that no longer exist so the selection stays valid.
    func scan(directory: String) async {
        guard !directory.isEmpty, !isScanning else { return }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let root = directory
        let extensions = DirectoryScanner.movieExtensions
        let groups = await Task.detached(priority: .userInitiated) {
            let found = FileScanner.scan(directory: URL(fileURLWithPath: root), extensions: extensions)
            return Self.group(files: found, root: root)
        }.value

        self.groups = groups
        let livePaths = Set(groups.flatMap { $0.files.map(\.path) })
        selection = selection.intersection(livePaths)
    }

    /// Permanently deletes the checked videos, updating progress as it goes,
    /// then rescans so the groups reflect what's left.
    ///
    /// Deletes are permanent (not sent to the Trash): this app targets network
    /// volumes, which generally don't support a Trash.
    func cleanSelected(directory: String) async {
        let targets = groups.flatMap { $0.files }.filter { selection.contains($0.path) }
        guard !targets.isEmpty, !isDeleting else { return }

        isDeleting = true
        deleteProgress = 0
        lastError = nil
        defer { isDeleting = false }

        var failures = 0
        for (index, target) in targets.enumerated() {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: target.path))
                    return true
                } catch {
                    return false
                }
            }.value
            if !ok { failures += 1 }
            deleteProgress = Double(index + 1) / Double(targets.count)
        }

        if failures > 0 {
            lastError = "\(failures) of \(targets.count) file(s) could not be deleted."
        }
        selection.removeAll()
        await scan(directory: directory)
    }

    // MARK: - Grouping

    /// Buckets `files` by their first path component beneath `root`, keeping
    /// only buckets with more than one video. Files sitting directly in `root`
    /// are bucketed under the root folder itself.
    nonisolated static func group(files: [ScannedFile], root: String) -> [DuplicateGroup] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let rootComps = rootURL.pathComponents

        var buckets: [String: [ScannedFile]] = [:]
        for file in files {
            let fileComps = URL(fileURLWithPath: file.path).standardizedFileURL.pathComponents
            // Path components between the root and the filename itself.
            guard fileComps.count > rootComps.count else { continue }
            let relativeDirs = fileComps[rootComps.count..<(fileComps.count - 1)]

            let groupURL: URL
            if let first = relativeDirs.first {
                groupURL = rootURL.appendingPathComponent(first)
            } else {
                // Video sits directly in the scanned root.
                groupURL = rootURL
            }
            buckets[groupURL.path, default: []].append(file)
        }

        return buckets
            .filter { $0.value.count > 1 }
            .map { directory, files in
                DuplicateGroup(
                    directory: directory,
                    name: URL(fileURLWithPath: directory).lastPathComponent,
                    files: files.sorted { $0.size > $1.size }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
