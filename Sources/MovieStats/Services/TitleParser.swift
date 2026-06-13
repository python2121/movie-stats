import Foundation

/// Best-effort extraction of a movie title (and release year, if present) from
/// a filename.
///
/// Strategy:
///   1. Strip any leading release-group tags like `[YIFY]` / `{rls}`.
///   2. Find the LAST 4-digit year (1900–2099) in the filename that isn't
///      glued to neighbouring letters/digits and isn't sitting at position 0
///      (titles like "2001 A Space Odyssey" start with a year-shaped number
///      that isn't the release year).
///   3. Take everything before the year as the title; clean trailing
///      punctuation / unmatched openers.
///   4. If no year exists, truncate at the first known quality-marker token
///      (BluRay, x264, 1080p, …) so the title doesn't carry encoder cruft.
///
/// This handles awkward shapes the original linear regex couldn't —
/// alternate titles in parens (`Der Untergang (Downfall) (2004)`), commas
/// (`Honey, I Shrunk The Kids 1989`), and missing-year cases
/// (`Demolition.Man.BluRay.1080p…`).
enum TitleParser {
    /// 4-digit release year (1900–2099) flanked on both sides by non-letter,
    /// non-digit characters so `1980s`, `198912`, `Mar1980`, and `EDGE2020`
    /// (release-group + counter glued together) don't false-match. Year is
    /// split into century + decade groups so we can reassemble it.
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\d])(19|20)(\d{2})(?![\p{L}\d])"#
    )

    /// Multi-disc / multi-part token. Matches `cd1`, `disc 2`, `disk-1`,
    /// `pt 2`, `part1`, `dvd1`, etc. case-insensitively. Leading and
    /// trailing edges must be a separator (or the string edge) so a
    /// title containing the literal word "Part" (e.g.
    /// "Harry Potter and the Deathly Hallows Part 1") still matches —
    /// the trailing digit is mandatory and the boundaries gate out
    /// embedded-into-other-words cases.
    private static let partRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[ ._-])(?:cd|disc|disk|pt|part|dvd)[ -]?(\d{1,2})(?=[ ._-]|$)"#
    )

    /// Repeated leading `[group]` / `{group}` release-group tags.
    private static let leadingTagsRegex = try! NSRegularExpression(
        pattern: #"^(?:[\[\{][^\]\}]+[\]\}]\s*\.?\s*)+"#
    )

    /// Lowercased tokens that mark the end of a title when no year is present.
    /// Tuned to common scene/release naming — codec names, resolutions, source
    /// indicators. Conservative on purpose: better to keep too much than to
    /// truncate a legitimate title token.
    private static let stopWords: Set<String> = [
        "bluray", "brrip", "webrip", "webdl", "web-dl", "hdtv", "hdrip",
        "dvdrip", "bdrip", "remux",
        "x264", "x265", "h264", "h265", "hevc", "av1", "vp9", "xvid", "divx",
        "720p", "1080p", "2160p", "4k", "uhd",
    ]

    struct Parsed: Equatable {
        let title: String
        let year: Int?
        /// Disc / part number when the filename embeds one of
        /// `cd<N>`, `disc<N>`, `disk<N>`, `pt<N>`, `part<N>`, or
        /// `dvd<N>` (case-insensitive, separator-tolerant). nil for
        /// single-file movies, which is the common case. Drives the
        /// multi-part collapse in the library list and the `- pt<N>`
        /// suffix the renamer emits.
        let partNumber: Int?

        init(title: String, year: Int?, partNumber: Int? = nil) {
            self.title = title
            self.year = year
            self.partNumber = partNumber
        }

        var displayName: String {
            if let year { return "\(title) (\(year))" }
            return title
        }
    }

    /// Hard-coded canonical names for filenames that the regex would either
    /// misparse or render as nonsense (fan restoration projects with their
    /// own naming conventions, etc.). The filename must START with the token
    /// (case-insensitive); first hit wins.
    private struct Override {
        let prefix: String
        let title: String
        let year: Int
    }

    private static let overrides: [Override] = [
        Override(prefix: "4k77", title: "4k77 Star Wars A New Hope Original Print Scan", year: 1977),
        Override(prefix: "4k80", title: "4k80 Star Wars Empire Strikes Back Original Print Scan", year: 1980),
        Override(prefix: "4k83", title: "4k83 Star Wars Return of the Jedi Original Print Scan", year: 1983),
    ]

    static func parse(filename: String) -> Parsed {
        let base = (filename as NSString).deletingPathExtension
        let lower = base.lowercased()
        for override in overrides where lower.hasPrefix(override.prefix) {
            return Parsed(title: override.title, year: override.year)
        }

        let stripped = stripLeadingTags(base)
        // Pull the part number out *before* year detection so the
        // title doesn't drag the `cd1` / `pt2` token into TMDB
        // search.
        let partNumber = extractPartNumber(stripped)
        let nsStripped = stripped as NSString
        let fullRange = NSRange(location: 0, length: nsStripped.length)

        let yearMatches = yearRegex.matches(in: stripped, range: fullRange)
            .filter { $0.range.location > 0 }
        if let lastMatch = yearMatches.last {
            let beforeYear = nsStripped.substring(to: lastMatch.range.location)
            let year = Int(
                nsStripped.substring(with: lastMatch.range(at: 1))
                    + nsStripped.substring(with: lastMatch.range(at: 2))
            )
            return Parsed(
                title: cleanTitle(stripPartToken(beforeYear)),
                year: year,
                partNumber: partNumber
            )
        }

        return Parsed(
            title: cleanTitle(stopAtQualityMarker(stripPartToken(stripped))),
            year: nil,
            partNumber: partNumber
        )
    }

    /// First part-number hit in the filename (1–99). nil when none.
    private static func extractPartNumber(_ s: String) -> Int? {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = partRegex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: s)
        else { return nil }
        return Int(s[valueRange])
    }

    /// Removes any `cd<N>` / `pt<N>` / etc. token so the cleaned
    /// title doesn't contain the disc marker.
    private static func stripPartToken(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = partRegex.firstMatch(in: s, range: range) else {
            return s
        }
        return ns.replacingCharacters(in: match.range, with: " ")
    }

    /// Removes one-or-more leading `[group]` / `{group}` tags and any trailing
    /// separator, so the rest of the parser doesn't trip on them.
    private static func stripLeadingTags(_ s: String) -> String {
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = leadingTagsRegex.firstMatch(in: s, range: range) {
            return ns.substring(from: match.range.upperBound)
        }
        return s
    }

    /// Returns the substring up to (but not including) the first stop-word
    /// token. If no stop word is hit, returns the input unchanged.
    private static func stopAtQualityMarker(_ s: String) -> String {
        let separators: Set<Character> = [".", "-", "_", " "]
        let tokens = s.split(whereSeparator: { separators.contains($0) })
        var kept: [Substring] = []
        for token in tokens {
            if stopWords.contains(token.lowercased()) { break }
            kept.append(token)
        }
        return kept.joined(separator: " ")
    }

    /// Replaces dots/underscores with spaces, collapses whitespace, then trims
    /// trailing characters that look like unmatched openers or stray
    /// separators left over from cutting off the year.
    private static func cleanTitle(_ raw: String) -> String {
        let withSpaces = raw
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let collapsed = withSpaces
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        var result = collapsed
        let trailingTrim: Set<Character> = [" ", ",", "-", "(", "[", "{"]
        while let last = result.last, trailingTrim.contains(last) {
            result.removeLast()
        }
        return result
    }
}
