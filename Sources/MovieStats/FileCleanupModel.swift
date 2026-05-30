import Foundation

/// Backs a cleanup window: scans the directory for files of one category,
/// tracks which rows are checked, and permanently deletes the selected ones
/// with progress. Shared by the Images and Text/NFO windows.
@MainActor
@Observable
final class FileCleanupModel {
    let category: CleanupCategory

    private(set) var files: [ScannedFile] = []
    private(set) var isScanning = false
    private(set) var isDeleting = false

    /// 0...1 progress for the current delete operation.
    private(set) var deleteProgress = 0.0

    /// Paths of the rows currently checked.
    var selection: Set<String> = []

    var lastError: String?

    var hasSelection: Bool { !selection.isEmpty }

    init(category: CleanupCategory) {
        self.category = category
    }

    /// Scans `directory` for this category's files, ordered by name. Prunes any
    /// checked rows that no longer exist so the selection stays valid after a
    /// refresh.
    func scan(directory: String) async {
        guard !directory.isEmpty, !isScanning else { return }

        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let url = URL(fileURLWithPath: directory)
        let extensions = category.extensions
        let found = await Task.detached(priority: .userInitiated) {
            FileScanner.scan(directory: url, extensions: extensions)
        }.value

        files = found.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        selection = selection.intersection(Set(found.map(\.path)))
    }

    /// Permanently deletes the checked files, updating a progress value as it
    /// goes, then rescans so the list reflects what's left.
    ///
    /// Deletes are permanent (not sent to the Trash): this app targets network
    /// volumes, which generally don't support a Trash.
    func cleanSelected(directory: String) async {
        let targets = files.filter { selection.contains($0.path) }
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
            lastError = "\(failures) of \(targets.count) \(category.noun)(s) could not be deleted."
        }
        selection.removeAll()
        await scan(directory: directory)
    }
}
