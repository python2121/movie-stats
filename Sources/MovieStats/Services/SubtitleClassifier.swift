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

    /// Pulls the language code, qualifier flags, and optional descriptor out
    /// of a filename like `Movie.commentary.eng.srt` or `Subs/Latin American.spa.srt`.
    /// Splits on common separators (including parens / brackets), then matches
    /// each token against the language / qualifier / descriptor tables.
    ///
    /// The descriptor is what distinguishes multiple same-language tracks —
    /// commentary, simplified vs traditional Chinese, regional Spanish, etc.
    /// Plex / Jellyfin display it as the track label, so two English tracks
    /// can coexist as `<base>.en.srt` and `<base>.en.commentary.srt`.
    static func parse(filename: String) -> (lang: String?, forced: Bool, sdh: Bool, descriptor: String?) {
        let stem = (filename as NSString).deletingPathExtension
        let tokens = stem.split(whereSeparator: { ".-_ ()[]".contains($0) }).map { $0.lowercased() }
        var lang: String?
        var forced = false
        var sdh = false
        var descriptor: String?
        // Multi-token SDH detection: catches `Hearing Impaired` /
        // `Hearing_Impaired` / `Hearing-Impaired` / `Hearing.Impaired` that
        // get split into two adjacent tokens by our separator-based
        // tokenizer. The single-token `hearingimpaired` is already in
        // `sdhTags` below.
        for i in tokens.indices.dropLast()
        where tokens[i] == "hearing" && tokens[i + 1] == "impaired" {
            sdh = true
            break
        }
        for token in tokens {
            if forcedTags.contains(token) { forced = true; continue }
            if sdhTags.contains(token) { sdh = true; continue }
            if descriptor == nil, let desc = descriptorMap[token] { descriptor = desc; continue }
            if lang == nil, let normalized = languageMap[token] { lang = normalized }
        }
        return (lang, forced, sdh, descriptor)
    }

    /// Composes a canonical subtitle filename:
    /// `{base}.{lang}.{descriptor}[.sdh][.forced].ext`. Drops segments that
    /// aren't set so the file remains a valid Plex / Jellyfin sidecar even
    /// with no tags. The descriptor ordering — language → descriptor →
    /// flags — keeps multi-token track labels reading naturally
    /// ("English commentary forced").
    static func compose(
        base: String,
        lang: String?,
        forced: Bool,
        sdh: Bool,
        descriptor: String?,
        ext: String
    ) -> String {
        var name = base
        if let lang { name += ".\(lang)" }
        if let descriptor { name += ".\(descriptor)" }
        if sdh { name += ".sdh" }
        if forced { name += ".forced" }
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    // MARK: - Lookup tables

    /// Descriptors that distinguish multiple same-language tracks. Plex /
    /// Jellyfin display these as the subtitle label. First-match-wins per
    /// filename — so `Director.Commentary.eng.srt` lands on `director`
    /// (first token), but `Commentary.eng.srt` lands on `commentary`.
    /// Region tokens are kept separate from language aliases so that e.g.
    /// `Brazilian.por.srt` becomes `.pt.brazilian.srt` instead of
    /// colliding with a plain `por.srt`.
    private static let descriptorMap: [String: String] = {
        var m: [String: String] = [:]
        let entries: [(canonical: String, aliases: [String])] = [
            ("commentary", ["commentary", "comm", "comment", "commentaries"]),
            ("director", ["director", "directors"]),
            ("cast", ["cast"]),
            ("crew", ["crew"]),
            ("behindthescenes", ["bts", "behindthescenes"]),
            ("simplified", ["simplified", "simp"]),
            ("traditional", ["traditional", "trad"]),
            ("brazilian", ["brazilian"]),
            ("latin", ["latin", "latinamerican"]),
            ("european", ["european"]),
            ("canadian", ["canadian"]),
            ("british", ["british"]),
        ]
        for entry in entries {
            for alias in entry.aliases { m[alias] = entry.canonical }
        }
        return m
    }()

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
            ("no", ["no", "nor", "nob", "nno", "norwegian"]),
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
            // Languages that appeared in scene releases as 3-letter codes
            // and fell through to the "no language detected" bucket,
            // causing avoidable conflicts on `.srt` (untagged) when
            // consolidated into Subs/.
            ("lv", ["lv", "lav", "latvian"]),
            ("lt", ["lt", "lit", "lithuanian"]),
            ("sk", ["sk", "slo", "slk", "slovak"]),
            ("sl", ["sl", "slv", "slovene", "slovenian"]),
            ("et", ["et", "est", "estonian"]),
            ("hr", ["hr", "hrv", "croatian"]),
            // Coverage for additional languages that crop up in scene
            // releases — Iberian regionals, Balkan languages, South Asian
            // languages, Nordic outliers, etc.
            ("ca", ["ca", "cat", "catalan"]),
            ("gl", ["gl", "glg", "galician"]),
            ("eu", ["eu", "eus", "baq", "basque"]),
            ("cy", ["cy", "wel", "cym", "welsh"]),
            ("ga", ["ga", "gle", "irish"]),
            ("is", ["is", "ice", "isl", "icelandic"]),
            ("af", ["af", "afr", "afrikaans"]),
            ("sw", ["sw", "swa", "swahili"]),
            ("sq", ["sq", "alb", "sqi", "albanian"]),
            ("sr", ["sr", "srp", "scc", "serbian"]),
            ("bs", ["bs", "bos", "bosnian"]),
            ("mk", ["mk", "mac", "mkd", "macedonian"]),
            ("tl", ["tl", "tgl", "fil", "tagalog", "filipino"]),
            ("bn", ["bn", "ben", "bengali"]),
            ("ta", ["ta", "tam", "tamil"]),
            ("te", ["te", "tel", "telugu"]),
            ("mr", ["mr", "mar", "marathi"]),
            ("pa", ["pa", "pan", "punjabi"]),
            ("ur", ["ur", "urd", "urdu"]),
        ]
        for entry in entries {
            for alias in entry.aliases { m[alias] = entry.canonical }
        }
        return m
    }()
}
