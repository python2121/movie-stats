import AppKit
import ImageIO

/// Produces small, downsampled thumbnails for image files.
///
/// Uses ImageIO so we never load full-resolution images into memory just to
/// show a tiny preview — important when a folder holds large photos.
enum Thumbnailer {
    /// Returns a thumbnail no larger than `maxPixel` on its longest edge, or
    /// `nil` if the file can't be read as an image. Safe to call off the main
    /// actor.
    static func thumbnail(forPath path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
