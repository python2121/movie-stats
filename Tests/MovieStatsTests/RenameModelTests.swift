import Foundation
import Testing
@testable import MovieStats

/// In-memory MovieScope for driving RenameModel without an AppModel or the
/// persistent `movies` table. Path/match mutations patch the snapshot, just
/// like ImportSession does.
@MainActor
private final class TestScope: MovieScope {
    var movies: [MovieFile]
    let directoryPath: String
    let store: MovieStore?

    init(movies: [MovieFile], directoryPath: String, store: MovieStore?) {
        self.movies = movies
        self.directoryPath = directoryPath
        self.store = store
    }

    func reloadFromStore() {}

    func setTMDBMatch(forPath path: String, tmdbID: Int?, confirmedYear: Int?, customEdition: String?) throws {
        guard let i = movies.firstIndex(where: { $0.path == path }) else { return }
        movies[i].tmdbId = tmdbID
        movies[i].confirmedYear = confirmedYear
        movies[i].customEdition = customEdition
    }

    func updatePath(oldPath: String, newPath: String, newFilename: String) throws {
        guard let i = movies.firstIndex(where: { $0.path == oldPath }) else { return }
        movies[i].path = newPath
        movies[i].filename = newFilename
    }
}

@MainActor
@Suite("RenameModel")
struct RenameModelTests {
    private func makeStore(_ dir: TempDir) throws -> MovieStore {
        try MovieStore(url: dir.url.appendingPathComponent("db.sqlite"))
    }

    private func upsert(_ store: MovieStore, id: Int, title: String) throws {
        let json = #"{"id":\#(id),"title":"\#(title)"}"#
        let detail = try JSONDecoder().decode(TMDBMovieDetail.self, from: Data(json.utf8))
        try store.upsertTMDBDetail(detail)
    }

    private func movie(_ path: String, tmdb: Int, year: Int, width: Int? = nil, height: Int? = nil) -> MovieFile {
        MovieFile(
            path: path,
            filename: (path as NSString).lastPathComponent,
            size: 1000,
            dateScanned: Date(),
            tmdbId: tmdb,
            confirmedYear: year,
            width: width,
            height: height
        )
    }

    // MARK: - Multi-movie folder split (the documented §6.4 behavior)

    @Test("A folder of several different movies splits each into its own scan-root wrapper, husk auto-pruned")
    func multiMovieFolderSplits() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 11, title: "Star Wars")
        try upsert(store, id: 1891, title: "The Empire Strikes Back")

        let swPath = dir.makeFile("Trilogy/4k77.mkv")
        let empPath = dir.makeFile("Trilogy/4k80.mkv")
        dir.makeFile("Trilogy/.DS_Store")  // hidden — should not block the prune

        let scope = TestScope(
            movies: [movie(swPath, tmdb: 11, year: 1977), movie(empPath, tmdb: 1891, year: 1980)],
            directoryPath: dir.path,
            store: store
        )
        let model = RenameModel(scope: scope)
        await model.reload()

        #expect(model.rows.count == 2)
        let swRow = try #require(model.rows.first { $0.path == swPath })
        #expect(swRow.plan == .createFolderAndMove)
        #expect(swRow.newFolderPath == dir.absolute("Star Wars (1977) {tmdb-11}"))

        await model.apply()

        #expect(dir.exists("Star Wars (1977) {tmdb-11}/Star Wars (1977) {tmdb-11}.mkv"))
        #expect(dir.exists("The Empire Strikes Back (1980) {tmdb-1891}/The Empire Strikes Back (1980) {tmdb-1891}.mkv"))
        // Husk pruned — only the hidden .DS_Store remained.
        #expect(!dir.exists("Trilogy"))
        // Scope snapshot reflects the new on-disk locations.
        #expect(scope.movies.allSatisfy { $0.path.contains("{tmdb-") })
    }

    @Test("Husk of a split multi-movie folder is preserved when a non-hidden file remains")
    func huskPreservedWithLeftover() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 11, title: "Star Wars")
        try upsert(store, id: 1891, title: "The Empire Strikes Back")

        // Two tracked movies => a real multi-movie split; both get pulled out.
        let a = dir.makeFile("Mixed/a.mkv")
        let b = dir.makeFile("Mixed/b.mkv")
        dir.makeFile("Mixed/leftover.txt")  // non-hidden, untracked

        let scope = TestScope(
            movies: [movie(a, tmdb: 11, year: 1977), movie(b, tmdb: 1891, year: 1980)],
            directoryPath: dir.path, store: store
        )
        let model = RenameModel(scope: scope)
        await model.reload()
        await model.apply()

        #expect(dir.exists("Star Wars (1977) {tmdb-11}/Star Wars (1977) {tmdb-11}.mkv"))
        // The husk survives because leftover.txt is still inside it.
        #expect(dir.exists("Mixed"))
        #expect(dir.exists("Mixed/leftover.txt"))
    }

    // MARK: - Standard plan shapes

    @Test("A single movie in its own folder is a .renameFolder")
    func singleMovieRenamesFolder() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 100, title: "Some Movie")

        let path = dir.makeFile("Some.Movie.2010/Some.Movie.2010.mkv")
        let scope = TestScope(movies: [movie(path, tmdb: 100, year: 2010)],
                              directoryPath: dir.path, store: store)
        let model = RenameModel(scope: scope)
        await model.reload()

        let row = try #require(model.rows.first)
        #expect(row.plan == .renameFolder)

        await model.apply()
        #expect(dir.exists("Some Movie (2010) {tmdb-100}/Some Movie (2010) {tmdb-100}.mkv"))
        #expect(!dir.exists("Some.Movie.2010"))
    }

    @Test("A loose top-level video is wrapped, and the scan root is never pruned")
    func looseTopLevelVideo() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 200, title: "Loose")

        let path = dir.makeFile("loose.mkv")
        let scope = TestScope(movies: [movie(path, tmdb: 200, year: 2000)],
                              directoryPath: dir.path, store: store)
        let model = RenameModel(scope: scope)
        await model.reload()

        let row = try #require(model.rows.first)
        #expect(row.plan == .createFolderAndMove)

        await model.apply()
        #expect(dir.exists("Loose (2000) {tmdb-200}/Loose (2000) {tmdb-200}.mkv"))
        // The guard `oldFolderPath != scanRoot` keeps the library root alive.
        #expect(dir.exists(""))
    }

    // MARK: - Multi-quality and duplicate handling

    @Test("Two encodes of the same movie get distinct [qualityTag] names in one wrapper")
    func multiQualityAlternateVersions() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 11, title: "Star Wars")

        let uhd = dir.makeFile("a.mkv")
        let hd = dir.makeFile("b.mkv")
        let scope = TestScope(
            movies: [
                movie(uhd, tmdb: 11, year: 1977, width: 3840, height: 2160),
                movie(hd, tmdb: 11, year: 1977, width: 1920, height: 1080),
            ],
            directoryPath: dir.path, store: store
        )
        let model = RenameModel(scope: scope)
        await model.reload()

        // Distinct paths => not flagged as duplicates; both stay checked.
        #expect(model.rows.allSatisfy { !$0.duplicateConflict })
        #expect(model.rows.allSatisfy { $0.hasQualitySuffix })

        await model.apply()
        #expect(dir.exists("Star Wars (1977) {tmdb-11}/Star Wars (1977) {tmdb-11} [4K].mkv"))
        #expect(dir.exists("Star Wars (1977) {tmdb-11}/Star Wars (1977) {tmdb-11} [1080p].mkv"))
    }

    @Test("Indistinguishable copies (no probe data) collide and start unchecked")
    func duplicateTargetsFlaggedAndUnchecked() async throws {
        let dir = TempDir()
        let store = try makeStore(dir)
        try upsert(store, id: 11, title: "Star Wars")

        let a = dir.makeFile("copy1.mkv")
        let b = dir.makeFile("copy2.mkv")
        let scope = TestScope(
            movies: [movie(a, tmdb: 11, year: 1977), movie(b, tmdb: 11, year: 1977)],
            directoryPath: dir.path, store: store
        )
        let model = RenameModel(scope: scope)
        await model.reload()

        // Same tmdb, same (missing) quality => identical target => conflict.
        #expect(model.rows.count == 2)
        #expect(model.rows.allSatisfy { $0.duplicateConflict })
        #expect(model.rows.allSatisfy { !$0.included })
    }
}
