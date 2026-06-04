import Foundation

/// Builds the CSV the File → Export menu writes. Pure: takes movies in,
/// returns text out.
///
/// Columns:
///   - **Name** — the file name
///   - **Content Type** — pipe-separated list of the classification plus any
///     HDR/Dolby Vision flags (e.g. `1080p Blu-ray Remux | HDR10 | Dolby Vision`)
///   - **Size** — human-readable file size
enum CSVExporter {
    static func libraryCSV(movies: [MovieFile]) -> String {
        var lines: [String] = ["Name,Content Type,Size"]

        let sorted = movies.sorted {
            $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
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

            lines.append([
                escape(movie.filename),
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
