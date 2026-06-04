import Foundation

/// Best-effort extraction of a movie title (and release year, if present) from
/// a filename. Strips leading bracketed tags like `[YIFY]`, captures the text
/// up to the first 4-digit year, and normalizes dots/underscores to spaces.
///
/// The regex matches the title prefix; everything after the year (codec,
/// resolution, release group, etc.) is ignored. When the regex fails — usually
/// because the file has no year — the cleaned-up filename minus extension is
/// returned.
enum TitleParser {
    /// Mirrors the user-provided pattern with two small additions:
    ///   - `[` / `]` join `(` and `.` as accepted year-wrapper characters, so
    ///     filenames like `Movie [2010]` aren't missed.
    ///   - `(?!\d)` after the year prevents a longer digit run (e.g. `198912`)
    ///     from being misread as the year `1989`.
    /// The year is split into century and last-two-digit capture groups so we
    /// can reassemble it.
    private static let regex = try! NSRegularExpression(
        pattern: #"^(?:\[[^\]]+\]\s*)*([\w\s\.\-]+?)(?:\s*[\(\.\[]?(19|20)(\d{2})(?!\d)[\)\.\]]?)"#
    )

    struct Parsed: Equatable {
        let title: String
        let year: Int?

        /// `Title (Year)` when a year was parsed, otherwise just the title.
        var displayName: String {
            if let year { return "\(title) (\(year))" }
            return title
        }
    }

    static func parse(filename: String) -> Parsed {
        let base = (filename as NSString).deletingPathExtension
        let nsBase = base as NSString
        let fullRange = NSRange(location: 0, length: nsBase.length)

        if let match = regex.firstMatch(in: base, range: fullRange),
           match.numberOfRanges >= 4 {
            let titleRange = match.range(at: 1)
            let centuryRange = match.range(at: 2)
            let decadeRange = match.range(at: 3)

            if titleRange.location != NSNotFound,
               centuryRange.location != NSNotFound,
               decadeRange.location != NSNotFound {
                let rawTitle = nsBase.substring(with: titleRange)
                let yearString = nsBase.substring(with: centuryRange) + nsBase.substring(with: decadeRange)
                return Parsed(title: clean(rawTitle), year: Int(yearString))
            }
        }

        return Parsed(title: clean(base), year: nil)
    }

    /// Turns `The.Matrix__Reloaded` into `The Matrix Reloaded`.
    private static func clean(_ raw: String) -> String {
        let replaced = raw
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let parts = replaced.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }
}
