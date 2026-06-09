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

    /// Total bytes of the currently checked videos.
    var selectedSize: Int64 {
        groups.reduce(Int64(0)) { sum, group in
            sum + group.files.reduce(Int64(0)) { groupSum, file in
                selection.contains(file.path) ? groupSum + file.size : groupSum
            }
        }
    }

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

    /// True when every video in `group` except the largest is checked.
    func allButLargestSelected(in group: DuplicateGroup) -> Bool {
        let candidates = group.files.dropFirst().map(\.path)
        guard !candidates.isEmpty else { return false }
        return candidates.allSatisfy { selection.contains($0) }
    }

    /// Checks every video in `group` except the largest. If they're already all
    /// checked, clears the selection for that group instead (so the button can
    /// double as an undo).
    func toggleSelectAllButLargest(in group: DuplicateGroup) {
        let candidates = group.files.dropFirst().map(\.path)
        guard !candidates.isEmpty else { return }
        if candidates.allSatisfy({ selection.contains($0) }) {
            for path in candidates { selection.remove(path) }
        } else {
            for path in candidates { selection.insert(path) }
        }
    }

    /// Scans `directory` for videos and rebuilds the grouped list. Prunes any
    /// checked rows that no longer exist so the selection stays valid.
    ///
    /// `includeRootLevel` controls whether videos sitting *directly* at the
    /// scan root are bucketed (as a virtual group keyed by the root itself)
    /// or skipped. The standalone library window leaves it off — multiple
    /// loose top-level movies in a library root are different movies, not
    /// duplicates. The import wizard turns it on because the source IS one
    /// movie's folder, so loose top-level MKVs are extras to be pruned.
    func scan(directory: String, includeRootLevel: Bool = false) async {
        guard !directory.isEmpty, !isScanning else { return }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let root = directory
        let extensions = DirectoryScanner.movieExtensions
        let groups = await Task.detached(priority: .userInitiated) {
            let found = FileScanner.scan(directory: URL(fileURLWithPath: root), extensions: extensions)
            return Self.group(files: found, root: root, includeRootLevel: includeRootLevel)
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
    func cleanSelected(directory: String, includeRootLevel: Bool = false) async {
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
        await scan(directory: directory, includeRootLevel: includeRootLevel)
    }

    // MARK: - Grouping

    /// Buckets `files` by their first path component beneath `root`, keeping
    /// only buckets with more than one video. Videos sitting directly in
    /// `root` are normally ignored — multiple loose top-level videos at a
    /// library root are different movies, not duplicates. Turn on
    /// `includeRootLevel` (used by the import wizard, where the scan root
    /// IS one movie's folder) to bucket those too, under a synthetic group
    /// keyed by the root itself.
    nonisolated static func group(
        files: [ScannedFile],
        root: String,
        includeRootLevel: Bool = false
    ) -> [DuplicateGroup] {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let rootComps = rootURL.pathComponents

        var buckets: [String: [ScannedFile]] = [:]
        for file in files {
            let fileComps = URL(fileURLWithPath: file.path).standardizedFileURL.pathComponents
            // Path components between the root and the filename itself.
            guard fileComps.count > rootComps.count else { continue }
            let relativeDirs = fileComps[rootComps.count..<(fileComps.count - 1)]

            if let first = relativeDirs.first {
                let groupURL = rootURL.appendingPathComponent(first)
                buckets[groupURL.path, default: []].append(file)
            } else if includeRootLevel {
                // Loose video at the scan root — bucket under the root.
                buckets[rootURL.path, default: []].append(file)
            }
        }

        // Library scope: only buckets with more than one video are
        // "duplicates" worth flagging — singletons in their own movie
        // folders are independent movies.
        //
        // Import scope (`includeRootLevel == true`): drop the count
        // threshold. The user wants a *full inventory* of every video
        // in the source — main movie + every nested extra in its own
        // subfolder — so they can prune anything that isn't the main
        // feature. Cases like Deliverance, where the main MKV sits at
        // the root and the single extra sits three folders deep, end
        // up with two single-entry buckets that would otherwise both
        // be hidden by a `> 1` filter.
        return buckets
            .filter { _, files in includeRootLevel || files.count > 1 }
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
