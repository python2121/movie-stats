import Foundation

/// Pure helpers for working with sidecar subtitle files alongside a video:
/// recognizing subtitle extensions and folder names, extracting language
/// codes + qualifier flags (forced / SDH) from common filename patterns,
/// and composing canonical Plex / Jellyfin-style subtitle filenames.
enum SubtitleClassifier {
    /// Lowercased extensions (without the dot) recognized as subtitle assets.
    static let extensions: Set<String> = [
        "srt",      // SubRip — most common
        "ass",      // Advanced SubStation Alpha
        "ssa",      // SubStation Alpha
        "sub",      // VobSub (paired with .idx)
        "idx",
        "vtt",      // WebVTT
        "sup",      // Blu-Ray PGS
        "smi",      // SAMI
    ]

    /// Lowercased folder names treated as "a folder full of subtitles" —
    /// the renamer canonicalizes any of these to `Subs/`.
    static let subtitleFolderAliases: Set<String> = [
        "subs", "subtitles", "subtitle", "sub", "subz", "s",
    ]

    /// The canonical name the renamer rewrites every subtitle folder to.
    /// `Subs` is what release groups produce and what Plex / Jellyfin both
    /// auto-scan.
    static let canonicalFolderName = "Subs"

    /// True if `ext` (without the leading dot) is a subtitle file extension.
    static func isSubtitleExtension(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// True if `folderName` matches one of the well-known subtitle folder
    /// aliases.
    static func isSubtitleFolderAlias(_ folderName: String) -> Bool {
        subtitleFolderAliases.contains(folderName.lowercased())
    }

    /// Pulls the language code + qualifier flags out of a filename like
    /// `Movie.2020.eng.forced.srt`. Splits on common separators, matches
    /// each token against the language / qualifier tables. Returns the
    /// first language match it finds.
    static func parse(filename: String) -> (lang: String?, forced: Bool, sdh: Bool) {
        let stem = (filename as NSString).deletingPathExtension
        let tokens = stem.split(whereSeparator: { ".-_ ".contains($0) }).map { $0.lowercased() }
        var lang: String?
        var forced = false
        var sdh = false
        for token in tokens {
            if forcedTags.contains(token) { forced = true; continue }
            if sdhTags.contains(token) { sdh = true; continue }
            if lang == nil, let normalized = languageMap[token] { lang = normalized }
        }
        return (lang, forced, sdh)
    }

    /// Composes a canonical subtitle filename: `{base}.{lang}[.sdh][.forced].ext`.
    /// Drops segments that aren't set so the file remains a valid Plex / Jellyfin
    /// sidecar even with no tags.
    static func compose(
        base: String,
        lang: String?,
        forced: Bool,
        sdh: Bool,
        ext: String
    ) -> String {
        var name = base
        if let lang { name += ".\(lang)" }
        if sdh { name += ".sdh" }
        if forced { name += ".forced" }
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    // MARK: - Lookup tables

    private static let forcedTags: Set<String> = ["forced", "force"]
    /// "hi" is *not* listed here intentionally — it's also the ISO 639-1 code
    /// for Hindi. Files actually meant as hearing-impaired conventionally use
    /// `.sdh.` or `.cc.` instead, and that's the reliable signal.
    private static let sdhTags: Set<String> = ["sdh", "cc", "hearingimpaired"]

    /// Any-form lowercased language token → ISO 639-1 short code. Covers
    /// 639-1 itself (identity), 639-2/3 aliases (eng→en, fra/fre→fr, …),
    /// and a handful of common English language names.
    private static let languageMap: [String: String] = {
        var m: [String: String] = [:]
        let entries: [(canonical: String, aliases: [String])] = [
            ("en", ["en", "eng", "english"]),
            ("fr", ["fr", "fre", "fra", "french"]),
            ("es", ["es", "spa", "esp", "spanish", "esmx", "es419", "eses"]),
            ("de", ["de", "deu", "ger", "german"]),
            ("it", ["it", "ita", "italian"]),
            ("pt", ["pt", "por", "portuguese", "ptbr", "ptpt"]),
            ("ru", ["ru", "rus", "russian"]),
            ("ja", ["ja", "jpn", "japanese"]),
            ("ko", ["ko", "kor", "korean"]),
            ("zh", ["zh", "chi", "zho", "cmn", "chinese", "mandarin", "cantonese"]),
            ("nl", ["nl", "nld", "dut", "dutch"]),
            ("pl", ["pl", "pol", "polish"]),
            ("sv", ["sv", "swe", "swedish"]),
            ("no", ["no", "nor", "norwegian"]),
            ("da", ["da", "dan", "danish"]),
            ("fi", ["fi", "fin", "finnish"]),
            ("tr", ["tr", "tur", "turkish"]),
            ("ar", ["ar", "ara", "arabic"]),
            ("he", ["he", "heb", "hebrew"]),
            ("cs", ["cs", "cze", "ces", "czech"]),
            ("hu", ["hu", "hun", "hungarian"]),
            ("ro", ["ro", "rum", "ron", "romanian"]),
            ("bg", ["bg", "bul", "bulgarian"]),
            ("uk", ["uk", "ukr", "ukrainian"]),
            ("el", ["el", "ell", "gre", "greek"]),
            ("th", ["th", "tha", "thai"]),
            ("vi", ["vi", "vie", "vietnamese"]),
            ("hi", ["hin", "hindi"]),
            ("id", ["id", "ind", "indonesian"]),
            ("ms", ["ms", "msa", "may", "malay"]),
            ("fa", ["fa", "per", "fas", "persian", "farsi"]),
        ]
        for entry in entries {
            for alias in entry.aliases { m[alias] = entry.canonical }
        }
        return m
    }()
}
