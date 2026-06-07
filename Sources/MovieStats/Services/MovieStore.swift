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

        let needsTitleBackfill = !present.contains("parsed_title")

        let columns: [(name: String, ddl: String)] = [
            ("parsed_title", "TEXT"),
            ("parsed_year", "INTEGER"),
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
            ("audio_languages", "TEXT"),
            ("subtitle_codecs", "TEXT"),
            ("subtitle_languages", "TEXT"),
            ("movie_type", "TEXT"),
            ("probed_at", "REAL"),
            ("tmdb_id", "INTEGER"),
            ("confirmed_year", "INTEGER"),
        ]
        let needsConfirmedYearBackfill = !present.contains("confirmed_year")
        for col in columns where !present.contains(col.name) {
            try exec("ALTER TABLE movies ADD COLUMN \(col.name) \(col.ddl);")
        }
        try exec("CREATE INDEX IF NOT EXISTS idx_movies_type ON movies(movie_type);")
        try exec("CREATE INDEX IF NOT EXISTS idx_movies_tmdb_id ON movies(tmdb_id);")

        try exec("""
            CREATE TABLE IF NOT EXISTS tmdb_movies (
                tmdb_id                    INTEGER PRIMARY KEY,
                imdb_id                    TEXT,
                title                      TEXT NOT NULL,
                original_title             TEXT,
                original_language          TEXT,
                tagline                    TEXT,
                overview                   TEXT,
                release_date               TEXT,
                runtime                    INTEGER,
                status                     TEXT,
                budget                     INTEGER,
                revenue                    INTEGER,
                popularity                 REAL,
                vote_average               REAL,
                vote_count                 INTEGER,
                adult                      INTEGER,
                video                      INTEGER,
                backdrop_path              TEXT,
                poster_path                TEXT,
                homepage                   TEXT,
                genres_json                TEXT,
                production_companies_json  TEXT,
                production_countries_json  TEXT,
                spoken_languages_json      TEXT,
                belongs_to_collection_json TEXT,
                matched_at                 REAL NOT NULL
            );
            """)

        // Additive migration for the per-country release dates payload so
        // older databases keep working without a re-confirm.
        var tmdbCols = Set<String>()
        var ts: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(tmdb_movies);", -1, &ts, nil) == SQLITE_OK {
            while sqlite3_step(ts) == SQLITE_ROW {
                if let c = sqlite3_column_text(ts, 1) {
                    tmdbCols.insert(String(cString: c))
                }
            }
            sqlite3_finalize(ts)
        }
        if !tmdbCols.contains("release_dates_json") {
            try exec("ALTER TABLE tmdb_movies ADD COLUMN release_dates_json TEXT;")
        }

        // IMDb ratings — bulk-loaded from `title.ratings.tsv.gz` on demand.
        // Joined into the main movies query via tmdb_movies.imdb_id.
        try exec("""
            CREATE TABLE IF NOT EXISTS imdb_ratings (
                imdb_id    TEXT PRIMARY KEY,
                avg_rating REAL NOT NULL,
                num_votes  INTEGER NOT NULL
            );
            """)
        // Single-row metadata: when we last pulled the dataset + how many
        // ratings landed. CHECK constraint pins the table to one row.
        try exec("""
            CREATE TABLE IF NOT EXISTS imdb_metadata (
                id                 INTEGER PRIMARY KEY CHECK (id = 1),
                last_downloaded_at REAL,
                entry_count        INTEGER
            );
            """)

        if needsTitleBackfill {
            try backfillParsedTitles()
        }
        if needsConfirmedYearBackfill {
            // One-time: for movies already matched to a TMDB record before
            // the confirmed_year column existed, use the filename's parsed
            // year as a best-guess of "what the user matched on". Newly-
            // confirmed rows populate confirmed_year directly.
            try exec("""
                UPDATE movies
                SET confirmed_year = parsed_year
                WHERE tmdb_id IS NOT NULL
                  AND confirmed_year IS NULL
                  AND parsed_year IS NOT NULL;
                """)
        }
    }

    /// Populates `parsed_title` / `parsed_year` for every row that doesn't
    /// have them yet. Runs once, right after the columns are first added so
    /// existing libraries don't need a manual rescan to get titles.
    private func backfillParsedTitles() throws {
        let selectSQL = "SELECT path, filename FROM movies WHERE parsed_title IS NULL OR parsed_title = '';"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }

        var pending: [(path: String, filename: String)] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(selectStmt, 0))
            let filename = String(cString: sqlite3_column_text(selectStmt, 1))
            pending.append((path, filename))
        }
        sqlite3_finalize(selectStmt)

        guard !pending.isEmpty else { return }

        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let updateSQL = "UPDATE movies SET parsed_title = ?, parsed_year = ? WHERE path = ?;"
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(updateStmt) }

            for row in pending {
                let parsed = TitleParser.parse(filename: row.filename)
                sqlite3_bind_text(updateStmt, 1, parsed.title, -1, SQLITE_TRANSIENT)
                if let year = parsed.year {
                    sqlite3_bind_int64(updateStmt, 2, Int64(year))
                } else {
                    sqlite3_bind_null(updateStmt, 2)
                }
                sqlite3_bind_text(updateStmt, 3, row.path, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                    throw MovieStoreError.exec(lastErrorMessage())
                }
                sqlite3_reset(updateStmt)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
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
                INSERT INTO movies (path, filename, size, date_scanned, parsed_title, parsed_year)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    filename = excluded.filename,
                    size = excluded.size,
                    date_scanned = excluded.date_scanned,
                    parsed_title = excluded.parsed_title,
                    parsed_year = excluded.parsed_year;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }

            for file in files {
                let parsed = TitleParser.parse(filename: file.filename)
                sqlite3_bind_text(stmt, 1, file.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, file.filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 3, file.size)
                sqlite3_bind_double(stmt, 4, now)
                sqlite3_bind_text(stmt, 5, parsed.title, -1, SQLITE_TRANSIENT)
                if let year = parsed.year {
                    sqlite3_bind_int64(stmt, 6, Int64(year))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
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

    /// Every persisted movie with full metadata, ordered by filename. Left-
    /// joins the TMDB record to pick up the IMDb ID, the canonical title +
    /// release date payload for the displayed name, then left-joins the
    /// IMDb ratings cache. Unmatched movies / missing ratings are left
    /// nil — the view layer handles the absence.
    func allMovies() throws -> [MovieFile] {
        let sql = """
            SELECT m.path, m.filename, m.size, m.date_scanned,
                   m.width, m.height, m.duration, m.bitrate,
                   m.video_codec, m.container, m.pix_fmt,
                   m.is_10bit, m.hdr_format, m.has_dolby_vision,
                   m.video_tracks, m.audio_tracks, m.subtitle_tracks,
                   m.audio_codecs, m.audio_channels, m.audio_languages,
                   m.subtitle_codecs, m.subtitle_languages,
                   m.movie_type, m.probed_at,
                   m.parsed_title, m.parsed_year,
                   m.tmdb_id,
                   t.imdb_id,
                   r.avg_rating, r.num_votes,
                   t.title, t.release_date, t.release_dates_json,
                   m.confirmed_year
            FROM movies m
            LEFT JOIN tmdb_movies t ON m.tmdb_id = t.tmdb_id
            LEFT JOIN imdb_ratings r ON t.imdb_id = r.imdb_id
            ORDER BY m.filename COLLATE NOCASE;
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
                audio_codecs = ?, audio_channels = ?, audio_languages = ?,
                subtitle_codecs = ?, subtitle_languages = ?,
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
        bindNullableText(stmt, 16, info.audioLanguages.joined(separator: ","))
        bindNullableText(stmt, 17, info.subtitleCodecs.joined(separator: ","))
        bindNullableText(stmt, 18, info.subtitleLanguages.joined(separator: ","))
        bindNullableText(stmt, 19, movieType)
        sqlite3_bind_double(stmt, 20, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 21, path, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    /// Wipes `probed_at` for every row so the next probing pass re-reads them
    /// all. Used by the "Reprobe" action.
    func clearAllMetadata() throws {
        try exec("UPDATE movies SET probed_at = NULL;")
    }

    /// Re-keys a movie row to a new on-disk location after a rename or move.
    /// The TMDB match, probed metadata, and parsed-title columns all stay
    /// intact because we're updating in place rather than insert-delete.
    func updatePath(oldPath: String, newPath: String, newFilename: String) throws {
        let sql = "UPDATE movies SET path = ?, filename = ? WHERE path = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, newPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, newFilename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, oldPath, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    // MARK: - TMDB matches

    /// Sets `movies.tmdb_id` and the locked-in `confirmed_year` for one
    /// file. The confirmed year is the year the matcher *showed the user*
    /// at the moment of confirm — pre-computed by the matcher (preferred
    /// post-mismatch year, falling back to the search-result year) — so
    /// downstream features (rename, display) use the exact year the user
    /// signed off on, even if TMDB's persisted release_date later derives
    /// to something different.
    ///
    /// Doesn't touch the `tmdb_movies` row — caller persists the detail
    /// separately via `upsertTMDBDetail` (so multiple file copies of the
    /// same movie share one row in `tmdb_movies`).
    func setTMDBMatch(forPath path: String, tmdbID: Int?, confirmedYear: Int?) throws {
        let sql = "UPDATE movies SET tmdb_id = ?, confirmed_year = ? WHERE path = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        if let tmdbID {
            sqlite3_bind_int64(stmt, 1, Int64(tmdbID))
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        if let confirmedYear {
            sqlite3_bind_int64(stmt, 2, Int64(confirmedYear))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_text(stmt, 3, path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    /// Inserts (or replaces) the full TMDB detail for `tmdb_id`. Complex
    /// nested objects are JSON-encoded so we don't drift from TMDB's shape.
    func upsertTMDBDetail(_ detail: TMDBMovieDetail) throws {
        let sql = """
            INSERT OR REPLACE INTO tmdb_movies (
                tmdb_id, imdb_id, title, original_title, original_language,
                tagline, overview, release_date, runtime, status,
                budget, revenue, popularity, vote_average, vote_count,
                adult, video, backdrop_path, poster_path, homepage,
                genres_json, production_companies_json, production_countries_json,
                spoken_languages_json, belongs_to_collection_json,
                release_dates_json,
                matched_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(detail.id))
        bindNullableText(stmt, 2, detail.imdbID)
        sqlite3_bind_text(stmt, 3, detail.title, -1, SQLITE_TRANSIENT)
        bindNullableText(stmt, 4, detail.originalTitle)
        bindNullableText(stmt, 5, detail.originalLanguage)
        bindNullableText(stmt, 6, detail.tagline)
        bindNullableText(stmt, 7, detail.overview)
        bindNullableText(stmt, 8, detail.releaseDate)
        bindNullableInt(stmt, 9, detail.runtime.map(Int64.init))
        bindNullableText(stmt, 10, detail.status)
        bindNullableInt(stmt, 11, detail.budget.map(Int64.init))
        bindNullableInt(stmt, 12, detail.revenue.map(Int64.init))
        bindNullableDouble(stmt, 13, detail.popularity)
        bindNullableDouble(stmt, 14, detail.voteAverage)
        bindNullableInt(stmt, 15, detail.voteCount.map(Int64.init))
        bindNullableBool(stmt, 16, detail.adult)
        bindNullableBool(stmt, 17, detail.video)
        bindNullableText(stmt, 18, detail.backdropPath)
        bindNullableText(stmt, 19, detail.posterPath)
        bindNullableText(stmt, 20, detail.homepage)
        bindJSON(stmt, 21, detail.genres)
        bindJSON(stmt, 22, detail.productionCompanies)
        bindJSON(stmt, 23, detail.productionCountries)
        bindJSON(stmt, 24, detail.spokenLanguages)
        bindJSON(stmt, 25, detail.belongsToCollection)
        bindJSON(stmt, 26, detail.releaseDates)
        sqlite3_bind_double(stmt, 27, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MovieStoreError.exec(lastErrorMessage())
        }
    }

    /// Reads a previously-cached TMDB detail back from disk, or nil if we've
    /// never matched this id.
    func tmdbDetail(forID id: Int) throws -> TMDBMovieDetail? {
        let sql = """
            SELECT tmdb_id, imdb_id, title, original_title, original_language,
                   tagline, overview, release_date, runtime, status,
                   budget, revenue, popularity, vote_average, vote_count,
                   adult, video, backdrop_path, poster_path, homepage,
                   genres_json, production_companies_json, production_countries_json,
                   spoken_languages_json, belongs_to_collection_json,
                   release_dates_json
            FROM tmdb_movies WHERE tmdb_id = ?;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MovieStoreError.prepare(lastErrorMessage())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(id))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return TMDBMovieDetail(
            id: Int(sqlite3_column_int64(stmt, 0)),
            imdbID: readNullableText(stmt, 1),
            title: readNullableText(stmt, 2) ?? "",
            originalTitle: readNullableText(stmt, 3),
            originalLanguage: readNullableText(stmt, 4),
            tagline: readNullableText(stmt, 5),
            overview: readNullableText(stmt, 6),
            releaseDate: readNullableText(stmt, 7),
            runtime: readNullableInt(stmt, 8),
            status: readNullableText(stmt, 9),
            budget: readNullableInt(stmt, 10),
            revenue: readNullableInt(stmt, 11),
            popularity: readNullableDouble(stmt, 12),
            voteAverage: readNullableDouble(stmt, 13),
            voteCount: readNullableInt(stmt, 14),
            adult: readNullableBool(stmt, 15),
            video: readNullableBool(stmt, 16),
            backdropPath: readNullableText(stmt, 17),
            posterPath: readNullableText(stmt, 18),
            homepage: readNullableText(stmt, 19),
            genres: decodeJSON(readNullableText(stmt, 20)),
            productionCompanies: decodeJSON(readNullableText(stmt, 21)),
            productionCountries: decodeJSON(readNullableText(stmt, 22)),
            spokenLanguages: decodeJSON(readNullableText(stmt, 23)),
            belongsToCollection: decodeJSON(readNullableText(stmt, 24)),
            releaseDates: decodeJSON(readNullableText(stmt, 25))
        )
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
        movie.audioLanguages = splitCSV(readNullableText(stmt, 19))
        movie.subtitleCodecs = splitCSV(readNullableText(stmt, 20))
        movie.subtitleLanguages = splitCSV(readNullableText(stmt, 21))
        movie.movieType = readNullableText(stmt, 22)
        movie.probedAt = readNullableDouble(stmt, 23).map { Date(timeIntervalSince1970: $0) }
        movie.parsedTitle = readNullableText(stmt, 24) ?? ""
        movie.parsedYear = readNullableInt(stmt, 25)
        movie.tmdbId = readNullableInt(stmt, 26)
        movie.imdbId = readNullableText(stmt, 27)
        movie.imdbRating = readNullableDouble(stmt, 28)
        movie.imdbVotes = readNullableInt(stmt, 29)
        movie.tmdbTitle = readNullableText(stmt, 30)
        // Canonical year derived from TMDB's release_dates. This is the
        // fallback when no `confirmed_year` is set on the movie row — i.e.
        // pre-confirmed-year DB rows, or unmatched movies.
        let releaseDate = readNullableText(stmt, 31)
        let releaseDates: TMDBReleaseDates? = decodeJSON(readNullableText(stmt, 32))
        if let date = TMDBMovieDetail.preferredReleaseDate(
            releaseDates: releaseDates,
            releaseDate: releaseDate
        ), date.count >= 4 {
            movie.tmdbYear = Int(date.prefix(4))
        }
        movie.confirmedYear = readNullableInt(stmt, 33)
        return movie
    }

    // MARK: - IMDb dataset

    /// Drops the existing IMDb ratings and bulk-inserts the supplied set
    /// in a single transaction. Returns the count actually written.
    /// Pinned to one transaction so the table never appears half-loaded
    /// to other reads.
    @discardableResult
    func replaceAllIMDbRatings(_ ratings: [(imdbID: String, rating: Double, votes: Int)]) throws -> Int {
        try exec("BEGIN IMMEDIATE TRANSACTION;")
        var inserted = 0
        do {
            try exec("DELETE FROM imdb_ratings;")
            let sql = "INSERT INTO imdb_ratings (imdb_id, avg_rating, num_votes) VALUES (?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MovieStoreError.prepare(lastErrorMessage())
            }
            defer { sqlite3_finalize(stmt) }
            for row in ratings {
                sqlite3_bind_text(stmt, 1, row.imdbID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, row.rating)
                sqlite3_bind_int64(stmt, 3, Int64(row.votes))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw MovieStoreError.exec(lastErrorMessage())
                }
                sqlite3_reset(stmt)
                inserted += 1
            }
            // Single-row metadata upsert.
            try exec("""
                INSERT OR REPLACE INTO imdb_metadata (id, last_downloaded_at, entry_count)
                VALUES (1, \(Date().timeIntervalSince1970), \(inserted));
                """)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return inserted
    }

    /// Single rating lookup by tconst. Used for ad-hoc queries; the main
    /// library list already JOINs and hydrates this via `allMovies`.
    func imdbRating(forIMDbID id: String) -> (rating: Double, votes: Int)? {
        let sql = "SELECT avg_rating, num_votes FROM imdb_ratings WHERE imdb_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (sqlite3_column_double(stmt, 0), Int(sqlite3_column_int64(stmt, 1)))
    }

    /// Returns the dataset's last-downloaded timestamp + how many ratings
    /// are cached. Both nil if the user has never imported.
    func imdbMetadata() -> (lastDownloadedAt: Date?, entryCount: Int) {
        let sql = "SELECT last_downloaded_at, entry_count FROM imdb_metadata WHERE id = 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (nil, 0) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, 0) }
        let ts = readNullableDouble(stmt, 0)
        let count = readNullableInt(stmt, 1) ?? 0
        return (ts.map { Date(timeIntervalSince1970: $0) }, count)
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

    private func bindNullableBool(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Bool?) {
        if let value {
            sqlite3_bind_int(stmt, idx, value ? 1 : 0)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func readNullableBool(_ stmt: OpaquePointer?, _ idx: Int32) -> Bool? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(stmt, idx) != 0
    }

    /// Encodes any `Encodable` value to a JSON string column. Stores SQL NULL
    /// for nil so we don't write empty payloads.
    private func bindJSON<T: Encodable>(_ stmt: OpaquePointer?, _ idx: Int32, _ value: T?) {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            sqlite3_bind_null(stmt, idx)
            return
        }
        sqlite3_bind_text(stmt, idx, string, -1, SQLITE_TRANSIENT)
    }

    /// Counterpart to `bindJSON`. Returns nil on missing/bad JSON.
    private func decodeJSON<T: Decodable>(_ text: String?) -> T? {
        guard let text, !text.isEmpty,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
