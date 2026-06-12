import Foundation

/// State + transport for the "Ask Claude" panel. Owns the chat transcript,
/// drives one streaming `claude` subprocess at a time, and exposes a single
/// status line for the UI while work is in flight.
@MainActor
@Observable
final class ChatModel {
    struct Message: Identifiable, Hashable {
        enum Role: Hashable { case user, assistant, system }
        let id = UUID()
        let role: Role
        var text: String
    }

    /// One transient status line shown beneath the transcript while streaming
    /// (e.g. "Querying database…"). Cleared when the model is idle.
    private(set) var statusLine: String?
    private(set) var isStreaming = false
    private(set) var messages: [Message] = []

    var input: String = ""

    var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    var hasClaudeCode: Bool { ClaudeCodeRunner.isAvailable }

    private var currentTask: Task<Void, Never>?
    /// `claude` session ID captured from the first turn's `system/init`
    /// event, then passed via `--resume` on every subsequent turn so prior
    /// context (system prompt + earlier messages) is restored automatically.
    /// Cleared by `clear()` so a fresh conversation starts a new session.
    private var sessionId: String?

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(Message(role: .user, text: question))
        isStreaming = true
        statusLine = "Thinking…"

        currentTask = Task { await stream(question: question) }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
        statusLine = nil
    }

    func clear() {
        cancel()
        messages.removeAll()
        sessionId = nil
    }

    private func stream(question: String) async {
        defer {
            isStreaming = false
            statusLine = nil
        }

        // First turn: prepend the system prompt so Claude has the schema and
        // ground rules. Subsequent turns: ride on the existing session, so we
        // only send the new user question.
        let prompt = sessionId == nil
            ? Self.systemPrompt + "\n\nUser question:\n\(question)"
            : question

        do {
            for try await event in ClaudeCodeRunner.stream(prompt: prompt, sessionId: sessionId) {
                if Task.isCancelled { break }
                apply(event: event)
            }
        } catch {
            messages.append(Message(role: .system, text: error.localizedDescription))
        }
    }

    private func apply(event: ClaudeCodeRunner.Event) {
        switch event {
        case .sessionStarted(let id):
            if sessionId == nil { sessionId = id }
        case .assistant(let blocks):
            for block in blocks {
                switch block {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        messages.append(Message(role: .assistant, text: trimmed))
                    }
                    statusLine = "Thinking…"
                case .toolUse(let name, let input):
                    statusLine = compactStatus(tool: name, input: input)
                }
            }
        case .toolResult:
            statusLine = "Thinking…"
        case .finalResult:
            statusLine = nil
        case .ignored:
            break
        }
    }

    private func compactStatus(tool: String, input: String) -> String {
        // Keep the status line short — show just the first line of the command
        // and snip past ~80 chars so long sqlite3 invocations don't blow up
        // the panel width.
        let firstLine = input.split(whereSeparator: \.isNewline).first.map(String.init) ?? input
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let truncated = trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        if truncated.isEmpty { return "Running \(tool)…" }
        return "Running \(tool): \(truncated)"
    }

    // MARK: - System prompt

    private static let systemPrompt: String = """
    You are an assistant embedded in MovieStats, a personal movie-library app.
    Answer the user's question about their library using the database below.

    Database: ~/Library/Application Support/MovieStats/moviestats.sqlite
    Always query with `sqlite3 -readonly`. Never modify the database (no
    UPDATE / INSERT / DELETE / ALTER / DROP / VACUUM / ATTACH).

    Table `movies` — one row per movie file on disk:
      path TEXT (PK), filename TEXT,
      parsed_title TEXT, parsed_year INTEGER,    -- inferred from filename
      size INTEGER (bytes), duration REAL (seconds), bitrate INTEGER (bps),
      width INTEGER, height INTEGER,
      video_codec TEXT, container TEXT, pix_fmt TEXT,
      is_10bit INTEGER (0/1), hdr_format TEXT ('HDR10' | 'HLG' | NULL),
      has_dolby_vision INTEGER (0/1),
      video_tracks INTEGER, audio_tracks INTEGER, subtitle_tracks INTEGER,
      audio_codecs TEXT (CSV), audio_channels TEXT (CSV),
      audio_languages TEXT (CSV ISO-639),
      subtitle_codecs TEXT (CSV), subtitle_languages TEXT (CSV ISO-639),
      movie_type TEXT, probed_at REAL,
      tmdb_id INTEGER,            -- FK → tmdb_movies.tmdb_id; NULL = unmatched
      watched_at REAL,            -- user marked watched (unix ts); NULL = unwatched
      personal_rating INTEGER,    -- user's own 1-5 star rating; NULL = unrated
      first_seen_at REAL          -- when the file first appeared in a scan
                                  -- (survives rescans = "added to library" date)

    movie_type values: '4K UHD Remux', '1080p Blu-ray Remux', '4K Encode',
      '1080p Encode', '720p Encode', 'SD', 'Unknown'

    Table `tmdb_movies` — canonical TMDB record per matched movie:
      tmdb_id INTEGER (PK), imdb_id TEXT,        -- tconst, e.g. 'tt0096694'
      title TEXT, original_title TEXT, original_language TEXT,
      tagline TEXT, overview TEXT,
      release_date TEXT (YYYY-MM-DD), runtime INTEGER (minutes),
      status TEXT, budget INTEGER, revenue INTEGER,
      popularity REAL, vote_average REAL, vote_count INTEGER,
      adult INTEGER (0/1), video INTEGER (0/1),
      backdrop_path TEXT, poster_path TEXT, homepage TEXT,
      genres_json TEXT,                -- [{id,name}]
      production_companies_json TEXT,  -- [{id,name,logo_path,origin_country}]
      production_countries_json TEXT,  -- [{iso_3166_1,name}]
      spoken_languages_json TEXT,      -- [{iso_639_1,name,english_name}]
      belongs_to_collection_json TEXT, -- {id,name,poster_path,backdrop_path}
      release_dates_json TEXT,         -- {results:[{iso_3166_1,release_dates:[{release_date,type,...}]}]}
      matched_at REAL
      → JSON columns are SQLite TEXT; use json_extract / json_each.

    Table `imdb_ratings` — bulk-loaded from IMDb's title.ratings.tsv.gz:
      imdb_id TEXT (PK),               -- joins to tmdb_movies.imdb_id
      avg_rating REAL (0-10), num_votes INTEGER
      → may be empty if user hasn't downloaded the dataset yet — check
        `SELECT entry_count FROM imdb_metadata WHERE id=1`. If 0/missing,
        tell the user to click the IMDb Ratings toolbar button.

    Table `imdb_metadata` — single-row marker:
      id INTEGER (= 1), last_downloaded_at REAL, entry_count INTEGER

    Table `subtitle_files` — sidecar subtitle files found on disk:
      path TEXT (PK),
      movie_path TEXT,            -- FK → movies.path; NULL = unattributed orphan
      filename TEXT, size INTEGER (bytes),
      language TEXT (ISO 639-1 or NULL when untagged),
      descriptor TEXT ('commentary' | 'traditional' | … | NULL),
      is_sdh INTEGER (0/1), is_forced INTEGER (0/1),
      format TEXT ('srt' | 'sup' | 'idx' | 'sub' | 'ass' | …),
      date_scanned REAL
      → embedded subtitle *tracks* live in movies.subtitle_codecs /
        subtitle_languages; this table is only the external sidecar files.

    Output rules:
      • For display titles, prefer the canonical TMDB title when the movie
        is matched. Standard join is:
          LEFT JOIN tmdb_movies t ON movies.tmdb_id = t.tmdb_id
          → display title: COALESCE(t.title, NULLIF(parsed_title,''), filename)
      • For years, prefer TMDB: COALESCE(substr(t.release_date,1,4), parsed_year)
        (or pull the earliest theatrical from release_dates_json with
        json_each when extra precision matters — types 1, 2, 3).
      • For IMDb ratings:
          LEFT JOIN imdb_ratings r ON t.imdb_id = r.imdb_id
      • For sizes, convert bytes → human-readable (round 1 decimal): GB if
        < 1024 GB, else TB.
      • Format multi-row answers as compact markdown tables (no extra
        commentary unless asked).
      • If a query returns nothing, say so plainly.
      • Cap LIMIT to 25 unless the user asks for more.

    About your own limits:
      • You're an LLM. The user knows. Skip generic "as an AI…" disclaimers.
      • When the answer lives in the database, query it and report the
        result directly. Don't hedge on something the DB just told you.
      • IMDb ratings, runtime, genres, overview, cast (via TMDB) all live
        in the DB now — query `tmdb_movies` / `imdb_ratings`, don't recall
        from training data.
      • For un-matched movies, your knowledge of mainstream films is fine
        but unreliable for obscure ones. Give your best answer concisely;
        if you genuinely don't know, say so in one line.
      • Don't apologize repeatedly. Don't restate the question. Just do
        the job.
    """
}
