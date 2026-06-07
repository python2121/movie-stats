import Foundation

/// Pure helpers for composing canonical Plex / Jellyfin / Radarr-style movie
/// filenames from a TMDB record + the user's preferences.
///
/// Convention used throughout:
///
///   `Title (Year) {tmdb-N}[ [Remux]].ext`
///
/// inside a folder of the same base (without the `[Remux]` tag):
///
///   `Title (Year) {tmdb-N}/`
///
/// Both Plex and Jellyfin parse `{tmdb-N}` and bypass title-based scraping
/// when it's present, which is why the ID embed is the killer move — it
/// sidesteps every year-disagreement / fuzzy-title ambiguity.
enum FilenameSanitizer {
    /// Hard cap on the composed base length. 255-byte filesystem limit,
    /// with headroom for extension + future tags.
    static let maxBaseLength = 200

    /// Strips / substitutes filesystem-illegal characters in a title without
    /// touching legitimate unicode (diacritics, non-Latin scripts, etc.).
    static func sanitize(_ raw: String) -> String {
        var s = raw
        // `:` is super common in movie titles ("Star Wars: A New Hope").
        // Replace with " -" so the meaning survives on Windows / SMB.
        s = s.replacingOccurrences(of: ":", with: " -")
        // Path separators.
        s = s.replacingOccurrences(of: "/", with: "-")
        s = s.replacingOccurrences(of: "\\", with: "-")
        // Windows-illegal characters — strip outright.
        let stripped: Set<Character> = ["?", "*", "<", ">", "|", "\""]
        s.removeAll(where: stripped.contains)
        // Collapse runs of whitespace.
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        // Strip leading/trailing whitespace + trailing dots (Windows-illegal).
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") || s.hasSuffix(" ") {
            s.removeLast()
        }
        // Truncate to a safe length.
        if s.count > maxBaseLength {
            s = String(s.prefix(maxBaseLength))
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Canonical folder name: `Title (Year) {tmdb-N}`. The `[Remux]` tag
    /// belongs on the *file*, not the folder.
    static func folderName(title: String, year: Int?, tmdbID: Int) -> String {
        var base = sanitize(title)
        if let year { base += " (\(year))" }
        base += " {tmdb-\(tmdbID)}"
        return base
    }

    /// Canonical file basename (no extension). Appends ` [Remux]` when the
    /// source file's path indicated a Remux — scanner-ignored, helpful for
    /// human eyes.
    static func fileBasename(title: String, year: Int?, tmdbID: Int, isRemux: Bool) -> String {
        var base = folderName(title: title, year: year, tmdbID: tmdbID)
        if isRemux { base += " [Remux]" }
        return base
    }

    /// True if `raw` contains any character or pattern the sanitizer would
    /// change — used by the rename view to surface "problem" files first.
    static func hasSpecialCharacters(_ raw: String) -> Bool {
        let trouble: Set<Character> = [":", "/", "\\", "?", "*", "<", ">", "|", "\""]
        if raw.contains(where: trouble.contains) { return true }
        if raw.contains("  ") { return true }
        if raw.hasSuffix(".") || raw.hasSuffix(" ") { return true }
        return false
    }

    /// Case-insensitive scan for the substring "remux" anywhere in `raw`.
    /// Used so a `Title.2020.UHD.Remux.HEVC.mkv` source carries the Remux
    /// hint through to the canonical filename.
    static func containsRemux(_ raw: String) -> Bool {
        raw.range(of: "remux", options: .caseInsensitive) != nil
    }
}
