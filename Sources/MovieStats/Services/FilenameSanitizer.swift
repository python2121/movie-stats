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
        // `:` is super common in movie titles ("Star Wars: A New Hope",
        // "3:10 to Yuma"). Replace with " - " (spaces on BOTH sides) so
        // the meaning survives on Windows / SMB and the dash never visually
        // attaches to an adjacent token (avoiding "3 -10" reading as
        // negative ten). The whitespace-collapse pass below cleans up the
        // double-space that this produces when the original was ": ".
        s = s.replacingOccurrences(of: ":", with: " - ")
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

    /// Canonical file basename (no extension). Composes:
    ///
    ///   `Title (Year) {tmdb-N}[ {edition-X}][ [qualityTag]]`
    ///
    /// - `{edition-X}` — user-typed label captured at matcher-confirm
    ///   time (e.g. "4K77 v1.4", "Director's Cut"). Both Plex and
    ///   Jellyfin parse it as an edition qualifier so multiple cuts of
    ///   the same TMDB id can coexist as alternate versions under one
    ///   wrapper folder.
    /// - `[qualityTag]` — single bracket slot for source-type / quality
    ///   metadata. For solo files this is just `"Remux"` (when the
    ///   source path indicated a Remux) or nil (otherwise). For
    ///   multi-quality cases — two files with the same tmdb + edition
    ///   that differ in resolution / HDR / source — the caller passes
    ///   a fuller tag like `"4K Remux"`, `"1080p HDR"`, etc. The slot
    ///   subsumes Remux into the fuller tag so we never emit double-
    ///   brackets like `[4K Remux] [Remux]`.
    static func fileBasename(
        title: String,
        year: Int?,
        tmdbID: Int,
        customEdition: String? = nil,
        qualityTag: String? = nil,
        partNumber: Int? = nil
    ) -> String {
        var base = folderName(title: title, year: year, tmdbID: tmdbID)
        // Edition is sanitized through the same path-safety pass as the
        // title; empty / whitespace-only editions emit nothing rather
        // than a literal `{edition-}` block.
        if let edition = customEdition {
            let sanitized = sanitize(edition)
            if !sanitized.isEmpty {
                base += " {edition-\(sanitized)}"
            }
        }
        if let qualityTag {
            let sanitized = sanitize(qualityTag)
            if !sanitized.isEmpty {
                base += " [\(sanitized)]"
            }
        }
        // Multi-disc / multi-part suffix in Plex / Jellyfin's
        // recognized `- pt<N>` form. Placed last so a 4K + 1080p
        // of the same disc still composes as
        // `Title (Year) {tmdb-N} [4K Remux] - pt1.mkv`.
        if let partNumber {
            base += " - pt\(partNumber)"
        }
        return base
    }

    /// Composes a quality-tag string from a movie's probed metadata.
    /// Combines resolution bucket + HDR/DV modifier + Remux flag into
    /// the order most familiar from scene release naming:
    ///
    ///   `"4K HDR Remux"`, `"4K DV"`, `"1080p Remux"`, `"720p"`, …
    ///
    /// Used by the renamer when multiple files share the same tmdb +
    /// edition slot and need a `[qualityTag]` suffix to distinguish
    /// them. Returns `"Unknown"` when the file hasn't been probed —
    /// such rows still get a non-empty tag so the duplicate-conflict
    /// detector flags them properly instead of silently colliding.
    static func qualityTag(
        width: Int?,
        height: Int?,
        isRemux: Bool,
        hdrFormat: String?,
        hasDolbyVision: Bool
    ) -> String {
        let resolution: String
        if let width {
            if width >= 3840 { resolution = "4K" }
            else if width >= 1920 { resolution = "1080p" }
            else if width >= 1280 { resolution = "720p" }
            else { resolution = "SD" }
        } else {
            resolution = "Unknown"
        }
        var parts: [String] = [resolution]
        // DV and HDR can coexist on the same file, but `[4K DV HDR]`
        // reads ugly and isn't standard scene shape — prefer DV when
        // both are present (DV file = HDR-capable, the HDR base layer
        // is implied).
        if hasDolbyVision {
            parts.append("DV")
        } else if hdrFormat != nil {
            parts.append("HDR")
        }
        if isRemux { parts.append("Remux") }
        return parts.joined(separator: " ")
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
