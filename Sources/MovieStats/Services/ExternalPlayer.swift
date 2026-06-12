import AppKit

/// Hands a video off to IINA when it's installed, falling back to the
/// system default player. IINA is a standalone app, not an embeddable
/// framework, so "play" always means launching it with the file.
enum ExternalPlayer {
    static var iinaURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina")
    }

    static var playerName: String { iinaURL != nil ? "IINA" : "Default Player" }

    static func play(path: String) {
        let file = URL(fileURLWithPath: path)
        if let iina = iinaURL {
            NSWorkspace.shared.open(
                [file],
                withApplicationAt: iina,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}
