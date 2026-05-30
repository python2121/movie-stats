import Foundation
import SQLite3

/// SQLite destructor sentinel. SQLite needs to know whether a bound string
/// outlives the call; `SQLITE_TRANSIENT` tells it to copy the bytes itself.
/// It isn't exposed to Swift, so we recreate it here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MovieStoreError: Error, CustomStringConvertible {
    case open(String)
    case exec(String)
    case prepare(String)

    var description: String {
        switch self {
        case .open(let m): return "Could not open database: \(m)"
        case .exec(let m): return "Database error: \(m)"
        case .prepare(let m): return "Could not prepare statement: \(m)"
        }
    }
}

/// A tiny, dependency-free wrapper around the system SQLite library.
///
/// The schema is deliberately simple today (path, filename, size) but the
/// table is the single source of truth for everything we'll learn about a
/// movie later — new metadata becomes new columns.
final class MovieStore {
    private var db: OpaquePointer?

    /// Opens (creating if needed) the database in Application Support and
    /// ensures the schema exists.
    init() throws {
        let url = try Self.databaseURL()
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw MovieStoreError.open(lastErrorMessage())
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS movies (
                path         TEXT PRIMARY KEY,
                filename     TEXT NOT NULL,
                size         INTEGER NOT NULL,
                date_scanned REAL NOT NULL
            );
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    /// Replaces the entire set of movies with the results of a fresh scan,
    /// inside a single transaction so the on-disk data is always consistent.
    func replaceAll(_ files: [ScannedFile]) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try exec("DELETE FROM movies;")

            let sql = """
                INSERT INTO movies (path, filename, size, date_scanned)
                VALUES (?, ?, ?, ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            let now = Date().timeIntervalSince1970
            for file in files {
                sqlite3_bind_text(stmt, 1, file.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, file.filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, file.size)
                sqlite3_bind_double(stmt, 4, now)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw MovieStoreError.exec(lastErrorMessage())
                }
                sqlite3_reset(stmt)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// All persisted movies, ordered by filename.
    func allMovies() throws -> [MovieFile] {
        let sql = "SELECT path, filename, size, date_scanned FROM movies ORDER BY filename COLLATE NOCASE;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var result: [MovieFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let filename = String(cString: sqlite3_column_text(stmt, 1))
            let size = sqlite3_column_int64(stmt, 2)
            let scanned = sqlite3_column_double(stmt, 3)
            result.append(
                MovieFile(
                    path: path,
                    filename: filename,
                    size: size,
                    dateScanned: Date(timeIntervalSince1970: scanned)
                )
            )
        }
        return result
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    private func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: cString)
    }

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("MovieStats", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("moviestats.sqlite")
    }
}
