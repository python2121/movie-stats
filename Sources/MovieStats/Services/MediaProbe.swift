import Foundation

/// Container for everything we extract from one file via `ffprobe`. Optional
/// numeric fields are nil when ffprobe doesn't report them (the file might
/// be audio-only, or the header didn't include the info).
struct MediaInfo: Sendable {
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var bitrate: Int?
    var videoCodec: String?
    var container: String?
    var pixFmt: String?
    var is10Bit: Bool
    /// "HDR10", "HLG", or nil. Dolby Vision is orthogonal (a row can be both
    /// HDR10 and DV at the same time on a UHD disc).
    var hdrFormat: String?
    var hasDolbyVision: Bool
    var videoTracks: Int
    var audioTracks: Int
    var subtitleTracks: Int
    /// Per-track audio codec names, in stream order (e.g. `["truehd", "ac3"]`).
    var audioCodecs: [String]
    /// Per-track audio channel counts, matched to `audioCodecs` by index.
    var audioChannels: [Int]
    var subtitleCodecs: [String]
}

/// Spawns `ffprobe` and parses its JSON output into a `MediaInfo`. The binary
/// is preferred from inside the .app bundle (Resources/ffprobe), with a
/// fallback to Homebrew paths for `swift run` development.
enum MediaProbe {
    /// Returns the resolved `ffprobe` executable URL, or nil if none is found.
    /// Cached to avoid repeated filesystem checks during a probe pass.
    static func locateBinary() -> URL? {
        if lookupCompleted { return cachedURL }
        cachedURL = resolveBinary()
        lookupCompleted = true
        return cachedURL
    }

    private nonisolated(unsafe) static var cachedURL: URL?
    private nonisolated(unsafe) static var lookupCompleted = false

    private static func resolveBinary() -> URL? {
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffprobe"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/local/bin/ffprobe"),
        ]
        let fm = FileManager.default
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    /// Probes one file. Runs ffprobe off the main actor; returns nil if the
    /// binary is missing or ffprobe can't make sense of the file.
    static func probe(path: String) async -> MediaInfo? {
        await Task.detached(priority: .userInitiated) {
            probeSync(path: path)
        }.value
    }

    private static func probeSync(path: String) -> MediaInfo? {
        guard let binary = locateBinary() else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return parse(data: data)
    }

    // MARK: - Parsing

    private static func parse(data: Data) -> MediaInfo? {
        let decoder = JSONDecoder()
        guard let result = try? decoder.decode(ProbeResult.self, from: data) else {
            return nil
        }

        let streams = result.streams ?? []
        let videoStreams = streams.filter { $0.codecType == "video" }
        let audioStreams = streams.filter { $0.codecType == "audio" }
        let subtitleStreams = streams.filter { $0.codecType == "subtitle" }

        // The first video stream is treated as the primary — that's what
        // resolution/codec/HDR flags refer to.
        let primary = videoStreams.first

        let pixFmt = primary?.pixFmt
        let is10Bit = pixFmt.map { $0.contains("10le") || $0.contains("10be") } ?? false
        let hdrFormat: String? = {
            switch primary?.colorTransfer {
            case "smpte2084": return "HDR10"
            case "arib-std-b67": return "HLG"
            default: return nil
            }
        }()
        let hasDolbyVision = (primary?.sideDataList ?? []).contains { side in
            (side.sideDataType ?? "").lowercased().contains("dovi")
        }

        return MediaInfo(
            width: primary?.width,
            height: primary?.height,
            durationSeconds: result.format?.duration.flatMap(Double.init),
            bitrate: result.format?.bitRate.flatMap(Int.init),
            videoCodec: primary?.codecName,
            container: result.format?.formatName,
            pixFmt: pixFmt,
            is10Bit: is10Bit,
            hdrFormat: hdrFormat,
            hasDolbyVision: hasDolbyVision,
            videoTracks: videoStreams.count,
            audioTracks: audioStreams.count,
            subtitleTracks: subtitleStreams.count,
            audioCodecs: audioStreams.map { $0.codecName ?? "" },
            audioChannels: audioStreams.map { $0.channels ?? 0 },
            subtitleCodecs: subtitleStreams.map { $0.codecName ?? "" }
        )
    }

    // MARK: - JSON shapes

    private struct ProbeResult: Decodable {
        let streams: [Stream]?
        let format: Format?
    }

    private struct Stream: Decodable {
        let codecType: String?
        let codecName: String?
        let width: Int?
        let height: Int?
        let pixFmt: String?
        let colorTransfer: String?
        let channels: Int?
        let sideDataList: [SideData]?

        enum CodingKeys: String, CodingKey {
            case codecType = "codec_type"
            case codecName = "codec_name"
            case width
            case height
            case pixFmt = "pix_fmt"
            case colorTransfer = "color_transfer"
            case channels
            case sideDataList = "side_data_list"
        }
    }

    private struct SideData: Decodable {
        let sideDataType: String?

        enum CodingKeys: String, CodingKey {
            case sideDataType = "side_data_type"
        }
    }

    private struct Format: Decodable {
        let formatName: String?
        let bitRate: String?
        let duration: String?

        enum CodingKeys: String, CodingKey {
            case formatName = "format_name"
            case bitRate = "bit_rate"
            case duration
        }
    }
}
