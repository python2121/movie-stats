import Foundation
import Testing
@testable import MovieStats

@Suite("DirectoryScanner")
struct DirectoryScannerTests {
    @Test("Finds movie files recursively, excludes non-movie extensions")
    func findsMoviesByExtension() {
        let dir = TempDir()
        dir.makeFile("Movie (2020)/Movie (2020).mkv")
        dir.makeFile("Movie (2020)/notes.txt")
        dir.makeFile("loose.mp4")

        let found = DirectoryScanner.scan(directory: dir.url).map(\.path)
        #expect(found.contains(dir.absolute("Movie (2020)/Movie (2020).mkv")))
        #expect(found.contains(dir.absolute("loose.mp4")))
        #expect(!found.contains(where: { $0.hasSuffix("notes.txt") }))
    }

    @Test("Videos under Plex extras folders are filtered out of the catalog",
          arguments: ["Featurettes", "Trailers", "Behind The Scenes", "Deleted Scenes"])
    func extrasFoldersExcluded(folder: String) {
        let dir = TempDir()
        let main = dir.makeFile("Some Movie/Some Movie.mkv")
        dir.makeFile("Some Movie/\(folder)/extra.mkv")

        let found = DirectoryScanner.scan(directory: dir.url).map(\.path)
        #expect(found.contains(main))
        #expect(!found.contains(where: { $0.contains("/\(folder)/") }))
    }

    @Test("Extras matching is case-insensitive on the whole component")
    func extrasCaseInsensitive() {
        let dir = TempDir()
        dir.makeFile("Movie/movie.mkv")
        dir.makeFile("Movie/FEATURETTES/clip.mkv")

        let found = DirectoryScanner.scan(directory: dir.url).map(\.path)
        #expect(found.count == 1)
    }

    @Test("A real title containing an extras word is not a false positive")
    func extrasWordInTitleNotFiltered() {
        // 'Other' is an extras folder name, but a movie wrapper literally
        // named with it as a full component should still be found because
        // the video sits directly in the wrapper, not under an 'Other/' dir.
        let dir = TempDir()
        let p = dir.makeFile("The Others (2001) {tmdb-1}/The Others (2001) {tmdb-1}.mkv")
        let found = DirectoryScanner.scan(directory: dir.url).map(\.path)
        #expect(found.contains(p))
    }
}
