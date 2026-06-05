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

    Table `movies`:
      path TEXT (PK), filename TEXT,
      parsed_title TEXT, parsed_year INTEGER,
      size INTEGER (bytes), duration REAL (seconds), bitrate INTEGER (bps),
      width INTEGER, height INTEGER,
      video_codec TEXT, container TEXT, pix_fmt TEXT,
      is_10bit INTEGER (0/1), hdr_format TEXT ('HDR10' | 'HLG' | NULL),
      has_dolby_vision INTEGER (0/1),
      video_tracks INTEGER, audio_tracks INTEGER, subtitle_tracks INTEGER,
      audio_codecs TEXT (CSV), audio_channels TEXT (CSV),
      audio_languages TEXT (CSV ISO-639),
      subtitle_codecs TEXT (CSV), subtitle_languages TEXT (CSV ISO-639),
      movie_type TEXT, probed_at REAL

    movie_type values: '4K UHD Remux', '1080p Blu-ray Remux', '4K Encode',
      '1080p Encode', '720p Encode', 'SD', 'Unknown'

    Output rules:
      • Use COALESCE(NULLIF(parsed_title, ''), filename) for display titles.
      • For sizes, convert bytes → human-readable (round 1 decimal): GB if
        < 1024 GB, else TB.
      • Format multi-row answers as compact markdown tables (no extra
        commentary unless asked).
      • If a query returns nothing, say so plainly.
      • Cap LIMIT to 25 unless the user asks for more.
    """
}
