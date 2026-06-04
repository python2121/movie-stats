import Foundation

/// Builds the CSV the File → Export menu writes. Pure: takes movies in,
/// returns text out.
///
/// Columns:
///   - **Title** — parsed movie title without the year (e.g. "The Matrix").
///     Falls back to the filename if parsing produced nothing.
///   - **Year** — release year parsed from the filename, or blank.
///   - **Content Type** — pipe-separated list of the classification plus any
///     HDR/Dolby Vision flags (e.g. `1080p Blu-ray Remux | HDR10 | Dolby Vision`)
///   - **Size** — human-readable file size
enum CSVExporter {
    static func libraryCSV(movies: [MovieFile]) -> String {
        var lines: [String] = ["Title,Year,Content Type,Size"]

        let sorted = movies.sorted {
            $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }

        for movie in sorted {
            var parts: [String] = []
            if let type = movie.movieType, !type.isEmpty {
                parts.append(type)
            }
            if let hdr = movie.hdrFormat, !hdr.isEmpty {
                parts.append(hdr)
            }
            if movie.hasDolbyVision {
                parts.append("Dolby Vision")
            }

            let typeList = parts.joined(separator: " | ")
            let size = ByteCountFormatter.string(fromByteCount: movie.size, countStyle: .file)
            let titleOnly = movie.parsedTitle.isEmpty ? movie.filename : movie.parsedTitle
            let yearStr = movie.parsedYear.map(String.init) ?? ""

            lines.append([
                escape(titleOnly),
                yearStr,
                escape(typeList),
                escape(size),
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes the value if it contains any of the CSV special characters and
    /// doubles up any embedded quotes per RFC 4180.
    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
