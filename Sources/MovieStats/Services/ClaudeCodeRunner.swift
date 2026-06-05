import Foundation

/// Spawns the `claude` CLI in non-interactive print mode and parses its
/// stream-json output into typed events for the chat panel.
///
/// We rely on Claude Code being installed and authenticated against the
/// user's Anthropic account, so the conversation is billed against their
/// existing subscription instead of needing a separate API key. We restrict
/// Bash usage to `sqlite3` invocations only.
enum ClaudeCodeRunner {
    /// Model alias passed via `--model`. `opus` resolves to the latest Opus
    /// model Claude Code knows about.
    static let modelAlias = "opus"

    /// Locations to check for the `claude` binary, in priority order. The
    /// npm-global install path (`~/.claude/local/claude`) is what the
    /// installer Anthropic ships actually uses; the homebrew paths and PATH
    /// lookup are fallbacks.
    static func locateBinary() -> URL? {
        if lookupCompleted { return cachedURL }
        cachedURL = resolveBinary()
        lookupCompleted = true
        return cachedURL
    }

    static var isAvailable: Bool { locateBinary() != nil }

    private nonisolated(unsafe) static var cachedURL: URL?
    private nonisolated(unsafe) static var lookupCompleted = false

    private static func resolveBinary() -> URL? {
        let fm = FileManager.default
        let candidates: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        if let viaWhich = whichClaude() {
            return URL(fileURLWithPath: viaWhich)
        }
        return nil
    }

    /// Creates (if needed) and returns an empty workspace directory we point
    /// `claude` at — keeps Claude Code's project-scope from spanning the
    /// user's home and triggering unrelated TCC / trust prompts.
    private static func ensureWorkspaceDirectory() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let workspace = support
            .appendingPathComponent("MovieStats", isDirectory: true)
            .appendingPathComponent("claude-workspace", isDirectory: true)
        do {
            try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
            return workspace
        } catch {
            return nil
        }
    }

    /// Falls back to a login-shell `which claude` so user-specific PATH
    /// additions (nvm, asdf, etc.) are picked up.
    private static func whichClaude() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    // MARK: - Events

    enum ContentBlock: Sendable {
        case text(String)
        case toolUse(name: String, input: String)
    }

    enum Event: Sendable {
        case sessionStarted(id: String)
        case assistant(blocks: [ContentBlock])
        case toolResult(success: Bool, text: String)
        case finalResult(text: String, isError: Bool)
        case ignored
    }

    enum RunnerError: Error, CustomStringConvertible {
        case binaryNotFound
        case startFailed(String)
        case nonZeroExit(Int32, String)

        var description: String {
            switch self {
            case .binaryNotFound:
                return "Claude Code (claude CLI) not found. Install it from claude.com/code and sign in, then reopen this window."
            case .startFailed(let m): return "Failed to start claude: \(m)"
            case .nonZeroExit(let code, let trail):
                let tail = trail.isEmpty ? "" : " — \(trail.suffix(400))"
                return "claude exited with status \(code)\(tail)"
            }
        }
    }

    /// Streams events from one `claude -p` run. Pass `sessionId` from a
    /// previous turn's `.sessionStarted` event to load prior context — Claude
    /// Code restores the saved transcript and continues from it, which is how
    /// we make the chat panel multi-turn. Cancelling the consuming task
    /// terminates the subprocess.
    static func stream(prompt: String, sessionId: String? = nil) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            guard let binary = locateBinary() else {
                continuation.finish(throwing: RunnerError.binaryNotFound)
                return
            }

            let process = Process()
            process.executableURL = binary
            var args: [String] = [
                "-p", prompt,
                "--output-format", "stream-json",
                "--verbose",
                "--model", modelAlias,
                "--allowed-tools", "Bash(sqlite3:*),WebSearch,WebFetch",
            ]
            if let sessionId {
                args.append(contentsOf: ["--resume", sessionId])
            }
            process.arguments = args

            // Pin the subprocess's working directory to a controlled, empty
            // folder we own. Without this, claude inherits the GUI app's CWD
            // (typically `/` for Finder/Spotlight launches), uses it as the
            // workspace root, and triggers TCC + trust prompts for every
            // protected directory it discovers in scope.
            if let workspace = ensureWorkspaceDirectory() {
                process.currentDirectoryURL = workspace
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: RunnerError.startFailed(error.localizedDescription))
                return
            }

            Task.detached {
                do {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        if Task.isCancelled { break }
                        let event = parseEvent(line)
                        if case .ignored = event { continue }
                        continuation.yield(event)
                    }
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let errTail = String(data: errData, encoding: .utf8) ?? ""
                        continuation.finish(throwing: RunnerError.nonZeroExit(process.terminationStatus, errTail))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Parsing

    private static func parseEvent(_ line: String) -> Event {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return .ignored
        }

        switch type {
        case "system":
            if (json["subtype"] as? String) == "init",
               let id = json["session_id"] as? String {
                return .sessionStarted(id: id)
            }
            return .ignored

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return .ignored
            }
            var blocks: [ContentBlock] = []
            for block in content {
                let kind = block["type"] as? String
                if kind == "text", let text = block["text"] as? String, !text.isEmpty {
                    blocks.append(.text(text))
                } else if kind == "tool_use", let name = block["name"] as? String {
                    let inputDict = block["input"] as? [String: Any] ?? [:]
                    let inputString = compactInputDescription(inputDict)
                    blocks.append(.toolUse(name: name, input: inputString))
                }
            }
            return blocks.isEmpty ? .ignored : .assistant(blocks: blocks)

        case "user":
            // Tool results come back as user messages with content blocks. We
            // surface a short status line so the UI can show "Bash returned …".
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return .ignored
            }
            for block in content where (block["type"] as? String) == "tool_result" {
                let isError = (block["is_error"] as? Bool) ?? false
                let raw = (block["content"] as? String) ?? ""
                return .toolResult(success: !isError, text: raw)
            }
            return .ignored

        case "result":
            let isError = (json["is_error"] as? Bool) ?? false
            let text = (json["result"] as? String) ?? ""
            return .finalResult(text: text, isError: isError)

        default:
            return .ignored
        }
    }

    /// Best-effort short description of a tool's input — keeps the UI compact.
    private static func compactInputDescription(_ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }
}
