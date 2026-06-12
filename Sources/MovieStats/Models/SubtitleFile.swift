import Foundation

/// A sidecar subtitle file discovered during a library scan. Embedded
/// subtitle *tracks* live on `MovieFile` (from ffprobe); this is the
/// on-disk `.srt` / `.sup` / `.idx` inventory.
struct SubtitleFile: Identifiable, Hashable, Sendable {
    var path: String
    /// Path of the movie this subtitle belongs to, or nil when the scanner
    /// couldn't attribute it to a single video (orphan).
    var moviePath: String?
    var filename: String
    var size: Int64
    /// ISO 639-1 code parsed from the filename, nil when untagged.
    var language: String?
    /// Same-language disambiguator ("commentary", "traditional", …).
    var descriptor: String?
    var isSDH: Bool
    var isForced: Bool
    /// Lowercased extension ("srt", "sup", "idx", …).
    var format: String

    var id: String { path }
}
