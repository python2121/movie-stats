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
/// The base `movies` table only stores file-scan facts (path / filename /
/// size). Anything ffprobe learns later is added in additional nullable
/// columns by `migrate()`, so older databases keep working untouched.
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
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    /// Adds any media-metadata columns that don't already exist. Each new
    /// column is nullable so existing rows stay valid until the next probe.
    private func migrate() throws {
        var present = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(movies);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) {
                    present.insert(String(cString: c))
                }
            }
            sqlite3_finalize(stmt)
        }

        let columns: [(name: String, ddl: String)] = [
            ("width", "INTEGER"),
            ("height", "INTEGER"),
            ("duration", "REAL"),
            ("bitrate", "INTEGER"),
            ("video_codec", "TEXT"),
            ("container", "TEXT"),
            ("pix_fmt", "TEXT"),
            ("is_10bit", "INTEGER"),
            ("hdr_format", "TEXT"),
            ("has_dolby_vision", "INTEGER"),
            ("video_tracks", "INTEGER"),
            ("audio_tracks", "INTEGER"),
            ("subtitle_tracks", "INTEGER"),
            ("audio_codecs", "TEXT"),
            ("audio_channels", "TEXT"),
            ("subtitle_codecs", "TEXT"),
            ("movie_type", "TEXT"),
            ("probed_at", "REAL"),
        ]
        for col in columns where !present.contains(col.name) {
            try exec("ALTER TABLE movies ADD COLUMN \(col.name) \(col.ddl);")
        }
        try exec("CREATE INDEX IF NOT EXISTS idx_movies_type ON movies(movie_type);")
    }

    /// Reconciles the table with the latest filesystem scan, all in one
    /// transaction. New paths are inserted; existing paths get filename/size
    /// refreshed but keep their probed metadata; paths that weren't seen this
    /// pass are deleted (they disappeared from disk).
    func replaceAll(_ files: [ScannedFile]) throws {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let now = Date().timeIntervalSince1970

            let upsertSQL = """
                INSERT INTO movies (path, filename, size, date_scanned)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    filename = excluded.filename,
                    size = excluded.size,
                    date_scanned = excluded.date_scanned;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

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

            // Anything not touched in this pass is gone from disk.
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM movies WHERE date_scanned < ?;", -1, &deleteStmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(deleteStmt) }
            sqlite3_bind_double(deleteStmt, 1, now)
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw MovieStoreError.exec(lastErrorMessage())
            }

            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Every persisted movie with full metadata, ordered by filename.
    func allMovies() throws -> [MovieFile] {
        let sql = """
            SELECT path, filename, size, date_scanned,
                   width, height, duration, bitrate,
                   video_codec, container, pix_fmt,
                   is_10bit, hdr_format, has_dolby_vision,
                   video_tracks, audio_tracks, subtitle_tracks,
                   audio_codecs, audio_channels, subtitle_codecs,
                   movie_type, probed_at
            FROM movies
            ORDER BY filename COLLATE NOCASE;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var result: [MovieFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(makeMovie(from: stmt))
        }
        return result
    }

    /// Paths + sizes for rows that haven't been probed yet. Used by the
    /// probing pass; size is returned alongside so the classifier doesn't
    /// have to look it up again.
    func filesMissingMetadata() throws -> [(path: String, size: Int64)] {
        let sql = "SELECT path, size FROM movies WHERE probed_at IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        var result: [(path: String, size: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let size = sqlite3_column_int64(stmt, 1)
            result.append((path: path, size: size))
        }
        return result
    }

    /// Writes a probe result for a single file. `movieType` is the classifier
    /// output; `probedAt` is set to now so the row is skipped next pass.
    func updateMetadata(path: String, info: MediaInfo, movieType: String) throws {
        let sql = """
            UPDATE movies SET
                width = ?, height = ?, duration = ?, bitrate = ?,
                video_codec = ?, container = ?, pix_fmt = ?,
                is_10bit = ?, hdr_format = ?, has_dolby_vision = ?,
                video_tracks = ?, audio_tracks = ?, subtitle_tracks = ?,
                audio_codecs = ?, audio_channels = ?, subtitle_codecs = ?,
                movie_type = ?, probed_at = ?
            WHERE path = ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        bindNullableInt(stmt, 1, info.width.map(Int64.init))
        bindNullableInt(stmt, 2, info.height.map(Int64.init))
        bindNullableDouble(stmt, 3, info.durationSeconds)
        bindNullableInt(stmt, 4, info.bitrate.map(Int64.init))
        bindNullableText(stmt, 5, info.videoCodec)
        bindNullableText(stmt, 6, info.container)
        bindNullableText(stmt, 7, info.pixFmt)
        sqlite3_bind_int(stmt, 8, info.is10Bit ? 1 : 0)
        bindNullableText(stmt, 9, info.hdrFormat)
        sqlite3_bind_int(stmt, 10, info.hasDolbyVision ? 1 : 0)
        sqlite3_bind_int(stmt, 11, Int32(info.videoTracks))
        sqlite3_bind_int(stmt, 12, Int32(info.audioTracks))
        sqlite3_bind_int(stmt, 13, Int32(info.subtitleTracks))
        bindNullableText(stmt, 14, info.audioCodecs.joined(separator: ","))
        bindNullableText(stmt, 15, info.audioChannels.map(String.init).joined(separator: ","))
        bindNullableText(stmt, 16, info.subtitleCodecs.joined(separator: ","))
        bindNullableText(stmt, 17, movieType)
        sqlite3_bind_double(stmt, 18, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 19, path, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    /// Wipes `probed_at` for every row so the next probing pass re-reads them
    /// all. Used by the "Reprobe" action.
    func clearAllMetadata() throws {
        try exec("UPDATE movies SET probed_at = NULL;")
    }

    // MARK: - Row hydration

    private func makeMovie(from stmt: OpaquePointer?) -> MovieFile {
        let path = String(cString: sqlite3_column_text(stmt, 0))
        let filename = String(cString: sqlite3_column_text(stmt, 1))
        let size = sqlite3_column_int64(stmt, 2)
        let scanned = sqlite3_column_double(stmt, 3)

        var movie = MovieFile(
            path: path,
            filename: filename,
            size: size,
            dateScanned: Date(timeIntervalSince1970: scanned)
        )
        movie.width = readNullableInt(stmt, 4)
        movie.height = readNullableInt(stmt, 5)
        movie.durationSeconds = readNullableDouble(stmt, 6)
        movie.bitrate = readNullableInt(stmt, 7)
        movie.videoCodec = readNullableText(stmt, 8)
        movie.container = readNullableText(stmt, 9)
        movie.pixFmt = readNullableText(stmt, 10)
        movie.is10Bit = sqlite3_column_int(stmt, 11) != 0
        movie.hdrFormat = readNullableText(stmt, 12)
        movie.hasDolbyVision = sqlite3_column_int(stmt, 13) != 0
        movie.videoTracks = Int(sqlite3_column_int(stmt, 14))
        movie.audioTracks = Int(sqlite3_column_int(stmt, 15))
        movie.subtitleTracks = Int(sqlite3_column_int(stmt, 16))
        movie.audioCodecs = splitCSV(readNullableText(stmt, 17))
        movie.audioChannels = splitCSV(readNullableText(stmt, 18)).compactMap(Int.init)
        movie.subtitleCodecs = splitCSV(readNullableText(stmt, 19))
        movie.movieType = readNullableText(stmt, 20)
        movie.probedAt = readNullableDouble(stmt, 21).map { Date(timeIntervalSince1970: $0) }
        return movie
    }

    // MARK: - Binding helpers

    private func bindNullableText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindNullableInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int64?) {
        if let value {
            sqlite3_bind_int64(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindNullableDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func readNullableInt(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, idx))
    }

    private func readNullableDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, idx)
    }

    private func readNullableText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, idx) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    private func splitCSV(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Misc helpers

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
