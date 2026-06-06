import Foundation

/// Describes a kind of file the user can scan for and clean up in its own
/// window. Adding a new cleanup window is just adding one of these.
struct CleanupCategory: Identifiable, Hashable {
    /// Stable id, also used as the SwiftUI window id.
    let id: String
    /// Window/section title, e.g. "Images".
    let title: String
    /// Singular noun for messages, e.g. "image".
    let noun: String
    /// Extensions to match, lowercased and without the dot.
    let extensions: Set<String>
    /// How to render the per-row preview.
    let preview: PreviewKind

    enum PreviewKind: Hashable {
        /// A downsampled image thumbnail.
        case image
        /// The first few lines of the file's text.
        case text
    }

    static let images = CleanupCategory(
        id: "images",
        title: "Images",
        noun: "image",
        extensions: [
            "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif",
            "heic", "heif", "webp", "raw", "cr2", "nef", "arw", "dng", "svg",
        ],
        preview: .image
    )

    static let text = CleanupCategory(
        id: "text",
        title: "Text & NFO Files",
        noun: "file",
        extensions: ["txt", "nfo", "rtf"],
        preview: .text
    )
}
