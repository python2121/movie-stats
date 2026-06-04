import Foundation

/// A folder somewhere beneath the scan root whose subtree contains no files
/// (ignoring hidden cruft like `.DS_Store`).
struct EmptyFolder: Identifiable, Hashable {
    let path: String
    let name: String

    var id: String { path }
}

/// Backs the "Empty Folders" window: walks the scan root and surfaces the
/// top-most recursively-empty directories so they can be deleted in one pass.
@MainActor
@Observable
final class EmptyFoldersModel {
    private(set) var folders: [EmptyFolder] = []
    private(set) var isScanning = false
    private(set) var isDeleting = false

    /// 0...1 progress for the current delete operation.
    private(set) var deleteProgress = 0.0

    /// Paths of the rows currently checked.
    var selection: Set<String> = []

    var lastError: String?

    var hasSelection: Bool { !selection.isEmpty }

    var allSelected: Bool {
        !folders.isEmpty && selection.count == folders.count
    }

    /// Checks every listed folder if not all are selected, otherwise clears the
    /// selection.
    func toggleSelectAll() {
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(folders.map(\.path))
        }
    }

    /// Walks `directory` looking for empty subtrees and rebuilds the list.
    /// Prunes any checked rows that no longer exist so the selection stays valid.
    func scan(directory: String) async {
        guard !directory.isEmpty, !isScanning else { return }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let root = directory
        let found = await Task.detached(priority: .userInitiated) {
            Self.findEmptyRoots(under: root)
        }.value

        self.folders = found
        let livePaths = Set(found.map(\.path))
        selection = selection.intersection(livePaths)
    }

    /// Permanently deletes the checked folders (and any hidden contents like
    /// `.DS_Store` inside them), updating progress as it goes, then rescans.
    func cleanSelected(directory: String) async {
        let targets = folders.filter { selection.contains($0.path) }
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
            lastError = "\(failures) of \(targets.count) folder(s) could not be deleted."
        }
        selection.removeAll()
        await scan(directory: directory)
    }

    // MARK: - Scanning

    /// Finds the top-most directories beneath `root` whose subtrees contain no
    /// files (skipping hidden entries). The root itself is never returned.
    nonisolated static func findEmptyRoots(under root: String) -> [EmptyFolder] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        var emptyPaths: Set<String> = []

        // DFS returning whether `url`'s subtree contains no files. Records every
        // recursively-empty directory it visits so we can later filter to the
        // top-most.
        @discardableResult
        func walk(_ url: URL) -> Bool {
            let contents = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            var subtreeHasFile = false
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if !walk(item) { subtreeHasFile = true }
                } else {
                    subtreeHasFile = true
                }
            }

            if !subtreeHasFile {
                emptyPaths.insert(url.standardizedFileURL.path)
                return true
            }
            return false
        }

        let rootContents = (try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for item in rootContents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { walk(item) }
        }

        // Keep only paths whose parent isn't itself empty — that's the top of
        // each empty subtree.
        let result = emptyPaths.compactMap { path -> EmptyFolder? in
            let parent = URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            guard !emptyPaths.contains(parent) else { return nil }
            return EmptyFolder(path: path, name: URL(fileURLWithPath: path).lastPathComponent)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
