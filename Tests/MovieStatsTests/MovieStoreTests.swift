import Foundation
import Testing
@testable import MovieStats

@Suite("MovieStore")
struct MovieStoreTests {
    /// Fresh store backed by a unique temp file, plus the TempDir keeping it
    /// (and the WAL/SHM siblings) alive for the test's duration.
    private func makeStore() throws -> (store: MovieStore, dir: TempDir) {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("moviestats.sqlite")
        return (try MovieStore(url: url), dir)
    }

    private func scanned(_ path: String, filename: String, size: Int64 = 1000) -> ScannedFile {
        ScannedFile(filename: filename, path: path, size: size)
    }

    @Test("replaceAll inserts rows and parses titles/years")
    func replaceAllInsertsAndParses() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([
            scanned("/m/The.Matrix.1999.mkv", filename: "The.Matrix.1999.mkv"),
            scanned("/m/Inception.2010.mkv", filename: "Inception.2010.mkv"),
        ])
        let movies = try store.allMovies()
        #expect(movies.count == 2)
        let matrix = try #require(movies.first { $0.path == "/m/The.Matrix.1999.mkv" })
        #expect(matrix.parsedTitle == "The Matrix")
        #expect(matrix.parsedYear == 1999)
    }

    @Test("setTMDBMatch persists tmdb id, confirmed year, and edition")
    func setTMDBMatch() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([scanned("/m/a.mkv", filename: "a.mkv")])
        try store.setTMDBMatch(forPath: "/m/a.mkv", tmdbID: 603, confirmedYear: 1999,
                               customEdition: "Director's Cut")
        let m = try #require(try store.allMovies().first)
        #expect(m.tmdbId == 603)
        #expect(m.confirmedYear == 1999)
        #expect(m.customEdition == "Director's Cut")
    }

    @Test("An all-whitespace edition collapses to nil")
    func whitespaceEditionBecomesNil() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([scanned("/m/a.mkv", filename: "a.mkv")])
        try store.setTMDBMatch(forPath: "/m/a.mkv", tmdbID: 1, confirmedYear: nil, customEdition: "   ")
        #expect(try store.allMovies().first?.customEdition == nil)
    }

    @Test("updatePath rekeys the row")
    func updatePath() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([scanned("/m/old.mkv", filename: "old.mkv")])
        try store.updatePath(oldPath: "/m/old.mkv", newPath: "/m/new.mkv", newFilename: "new.mkv")
        let movies = try store.allMovies()
        #expect(movies.count == 1)
        #expect(movies.first?.path == "/m/new.mkv")
        #expect(movies.first?.filename == "new.mkv")
    }

    @Test("Watch state and personal rating round-trip, and clear back to nil")
    func watchAndRating() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([scanned("/m/a.mkv", filename: "a.mkv")])
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.setWatched(path: "/m/a.mkv", watchedAt: when)
        try store.setPersonalRating(path: "/m/a.mkv", rating: 4)
        var m = try #require(try store.allMovies().first)
        #expect(m.personalRating == 4)
        #expect(m.watchedAt.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)

        try store.setWatched(path: "/m/a.mkv", watchedAt: nil)
        try store.setPersonalRating(path: "/m/a.mkv", rating: nil)
        m = try #require(try store.allMovies().first)
        #expect(m.watchedAt == nil)
        #expect(m.personalRating == nil)
    }

    @Test("A rescan deletes paths that vanished but preserves first_seen_at")
    func rescanDeletesMissingPreservesFirstSeen() throws {
        let (store, dir) = try makeStore()
        _ = dir
        try store.replaceAll([
            scanned("/m/a.mkv", filename: "a.mkv"),
            scanned("/m/b.mkv", filename: "b.mkv"),
        ])
        let firstSeenB = try #require(try store.allMovies().first { $0.path == "/m/b.mkv" }?.firstSeenAt)

        // Second scan: 'a' is gone, 'b' remains (re-stated).
        try store.replaceAll([scanned("/m/b.mkv", filename: "b.mkv", size: 2000)])
        let after = try store.allMovies()
        #expect(after.count == 1)
        let b = try #require(after.first)
        #expect(b.path == "/m/b.mkv")
        #expect(b.size == 2000)
        // first_seen_at is stamped once and survives rescans.
        #expect(b.firstSeenAt.map { Int($0.timeIntervalSince1970) }
                == Int(firstSeenB.timeIntervalSince1970))
    }

    @Test("IMDb ratings bulk-load and read back by tconst")
    func imdbRatings() throws {
        let (store, dir) = try makeStore()
        _ = dir
        let count = try store.replaceAllIMDbRatings([
            (imdbID: "tt0133093", rating: 8.7, votes: 2_000_000),
            (imdbID: "tt1375666", rating: 8.8, votes: 2_500_000),
        ])
        #expect(count == 2)
        let r = try #require(store.imdbRating(forIMDbID: "tt0133093"))
        #expect(r.rating == 8.7)
        #expect(r.votes == 2_000_000)
        #expect(store.imdbRating(forIMDbID: "tt0000000") == nil)
    }

    @Test("Reopening the same database file is idempotent (migrations re-run cleanly)")
    func reopenIsIdempotent() throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("moviestats.sqlite")
        do {
            let store = try MovieStore(url: url)
            try store.replaceAll([scanned("/m/a.mkv", filename: "a.mkv")])
        }
        // Second open against the populated file must succeed and keep data.
        let reopened = try MovieStore(url: url)
        #expect(try reopened.allMovies().count == 1)
    }
}
