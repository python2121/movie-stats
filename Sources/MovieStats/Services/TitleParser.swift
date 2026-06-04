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
    /// 4-digit release year (1900–2099) flanked by non-digit, non-letter
    /// characters so `1980s`, `198912`, and `Mar1980` don't false-match.
    /// Year is split into century + decade groups so we can reassemble it.
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(19|20)(\d{2})(?![\p{L}\d])"#
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
        let nsStripped = stripped as NSString
        let fullRange = NSRange(location: 0, length: nsStripped.length)

        let yearMatches = yearRegex.matches(in: stripped, range: fullRange)
            .filter { $0.range.location > 0 }
        if let lastMatch = yearMatches.last {
            let beforeYear = nsStripped.substring(to: lastMatch.range.location)
            let centuryStr = nsStripped.substring(with: lastMatch.range(at: 1))
            let decadeStr = nsStripped.substring(with: lastMatch.range(at: 2))
            let year = Int(centuryStr + decadeStr)
            return Parsed(title: cleanTitle(beforeYear), year: year)
        }

        return Parsed(title: cleanTitle(stopAtQualityMarker(stripped)), year: nil)
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
