import Foundation

/// A single movie file discovered during a directory scan.
///
/// Intentionally minimal for now — `filename`, `path`, and `size`. Over time
/// this will grow to hold metadata (resolution, codec, runtime, …) by adding
/// columns to the `movies` table and fields here; nothing else needs to change.
struct MovieFile: Identifiable, Hashable, Sendable {
    /// Full filesystem path; also the primary key in the database.
    var path: String
    /// Just the file name, e.g. "The Matrix (1999).mkv".
    var filename: String
    /// File size in bytes.
    var size: Int64
    /// When this file was last seen by a scan.
    var dateScanned: Date

    var id: String { path }
}
