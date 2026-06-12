import Foundation

/// Discovers sidecar subtitle files during a library scan and attributes
/// each one to the movie it belongs to. Pure — safe off the main actor.
enum SubtitleScanner {
    static func scan(directory url: URL, videos: [ScannedFile]) -> [SubtitleFile] {
        let files = FileScanner.scan(directory: url, extensions: SubtitleClassifier.extensions)
        guard !files.isEmpty else { return [] }

        var videosByDir: [String: [ScannedFile]] = [:]
        for video in videos {
            let dir = (video.path as NSString).deletingLastPathComponent
            videosByDir[dir, default: []].append(video)
        }

        let root = url.path
        return files.map { file in
            let parsed = SubtitleClassifier.parse(filename: file.filename)
            return SubtitleFile(
                path: file.path,
                moviePath: owningVideo(
                    subtitlePath: file.path,
                    subtitleFilename: file.filename,
                    root: root,
                    videosByDir: videosByDir
                ),
                filename: file.filename,
                size: file.size,
                language: parsed.lang,
                descriptor: parsed.descriptor,
                isSDH: parsed.sdh,
                isForced: parsed.forced,
                format: (file.filename as NSString).pathExtension.lowercased()
            )
        }
    }

    /// Walks up from the subtitle's folder toward the scan root until a
    /// directory directly containing videos is found — this covers siblings,
    /// `Subs/`, and nested per-language folders inside `Subs/`. Within that
    /// directory, a video whose basename prefixes the subtitle's filename
    /// wins; otherwise a sole video wins; with several videos and no prefix
    /// match the subtitle stays unattributed rather than guessing.
    private static func owningVideo(
        subtitlePath: String,
        subtitleFilename: String,
        root: String,
        videosByDir: [String: [ScannedFile]]
    ) -> String? {
        let subLower = subtitleFilename.lowercased()
        var dir = (subtitlePath as NSString).deletingLastPathComponent
        while true {
            if let candidates = videosByDir[dir] {
                if let prefixed = candidates.first(where: { video in
                    let base = (video.filename as NSString).deletingPathExtension.lowercased()
                    return !base.isEmpty && subLower.hasPrefix(base)
                }) {
                    return prefixed.path
                }
                if candidates.count == 1 { return candidates[0].path }
                return nil
            }
            if dir == root || !dir.hasPrefix(root) { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}
