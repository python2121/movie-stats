import Foundation

/// The library category we assign to a movie based on its resolution, video
/// codec, and file size. Stored as `rawValue` text in the database so future
/// search queries are simple `WHERE movie_type = ?` lookups.
enum MovieType: String, CaseIterable, Sendable {
    case uhdRemux = "4K UHD Remux"
    case bluRayRemux = "1080p Blu-ray Remux"
    case uhdEncode = "4K Encode"
    case fullHDEncode = "1080p Encode"
    case hdEncode = "720p Encode"
    case sd = "SD"
    case unknown = "Unknown"
}

/// Pure classification rules. Tweak the thresholds and codec set here — every
/// other layer of the app reads through this one function.
enum MovieClassifier {
    /// Codec names (ffprobe's `codec_name`) that real Blu-ray / UHD Blu-ray
    /// discs use. Anything outside this set, even at remux-like sizes, is
    /// treated as a re-encode.
    static let remuxCodecs: Set<String> = ["h264", "hevc", "vc1", "mpeg2video"]

    /// Minimum size for a 1080p file in a remux-grade codec to count as a
    /// Blu-ray Remux. Real-world 1080p remuxes are usually 20–35 GB; we set the
    /// floor a bit lower to be forgiving of short runtimes.
    static let bluRayRemuxMinSize: Int64 = 15 * 1024 * 1024 * 1024

    /// Minimum size for a 4K file in a remux-grade codec to count as a UHD
    /// Remux. Real-world 4K UHD remuxes are 50–80 GB; 30 GB floor accommodates
    /// shorter films.
    static let uhdRemuxMinSize: Int64 = 30 * 1024 * 1024 * 1024

    static func classify(width: Int?, height: Int?, codec: String?, size: Int64) -> MovieType {
        guard let width, let height, width > 0, height > 0 else {
            return .unknown
        }

        // Width is the more reliable dimension for resolution buckets — a
        // cinemascope 1080p movie has height 800, but width is still 1920.
        let longSide = max(width, height)
        let codecLower = codec?.lowercased() ?? ""
        let isRemuxCodec = remuxCodecs.contains(codecLower)

        if longSide >= 3000 {
            // 4K territory: covers UHD (3840) and DCI 4K (4096).
            if isRemuxCodec && size >= uhdRemuxMinSize { return .uhdRemux }
            return .uhdEncode
        }
        if longSide >= 1700 {
            // 1080p territory: covers 1920 (and ~2K cinema close to it).
            if isRemuxCodec && size >= bluRayRemuxMinSize { return .bluRayRemux }
            return .fullHDEncode
        }
        if longSide >= 1100 {
            // 720p territory: covers 1280.
            return .hdEncode
        }
        return .sd
    }
}
