import Foundation
import Testing
@testable import MovieStats

@Suite("DuplicatesModel.group")
struct DuplicatesGroupingTests {
    private let root = "/media/movies"

    private func file(_ relative: String, size: Int64 = 1) -> ScannedFile {
        let path = "\(root)/\(relative)"
        return ScannedFile(filename: (path as NSString).lastPathComponent, path: path, size: size)
    }

    @Test("Library scope keeps only folders with more than one video")
    func libraryScopeKeepsMultiVideoFolders() {
        let files = [
            file("A/x.mkv"), file("A/y.mkv"),  // 2 → kept
            file("B/z.mkv"),                   // 1 → dropped
            file("loose.mkv"),                 // root-level → ignored
        ]
        let groups = DuplicatesModel.group(files: files, root: root)
        #expect(groups.count == 1)
        #expect(groups.first?.name == "A")
        #expect(groups.first?.files.count == 2)
    }

    @Test("Nested videos bucket under their top-level component")
    func nestedVideosBucketByTopComponent() {
        let files = [file("A/x.mkv"), file("A/sub/deep.mkv")]
        let groups = DuplicatesModel.group(files: files, root: root)
        #expect(groups.count == 1)
        #expect(groups.first?.files.count == 2)
    }

    @Test("Import scope keeps singletons and a synthetic root-level group")
    func importScopeIncludesEverything() {
        let files = [
            file("A/x.mkv"), file("A/y.mkv"), // 2
            file("B/z.mkv"),                  // singleton, still kept
            file("loose.mkv"),                // root-level synthetic bucket
        ]
        let groups = DuplicatesModel.group(files: files, root: root, includeRootLevel: true)
        #expect(groups.count == 3)
        #expect(groups.map(\.files.count).reduce(0, +) == 4)
    }

    @Test("Files are sorted largest-first within a group")
    func filesSortedBySizeDescending() {
        let files = [file("A/small.mkv", size: 10), file("A/big.mkv", size: 100)]
        let groups = DuplicatesModel.group(files: files, root: root)
        #expect(groups.first?.files.first?.filename == "big.mkv")
    }
}
