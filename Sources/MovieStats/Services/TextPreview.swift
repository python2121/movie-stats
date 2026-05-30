import Foundation

/// Produces a tiny text snippet (the first chunk of a file) for previews,
/// without reading the whole file into memory. Safe to call off the main actor.
enum TextPreview {
    /// Returns up to the first `maxBytes` of the file decoded as text, or `nil`
    /// if it can't be read.
    static func snippet(forPath path: String, maxBytes: Int = 512) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard !data.isEmpty else { return "" }

        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
