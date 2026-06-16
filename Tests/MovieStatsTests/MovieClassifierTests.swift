import Testing
@testable import MovieStats

private let GB: Int64 = 1024 * 1024 * 1024

@Suite("MovieClassifier")
struct MovieClassifierTests {
    @Test("Missing or zero dimensions classify as Unknown")
    func unknownWithoutDimensions() {
        #expect(MovieClassifier.classify(width: nil, height: nil, codec: "hevc", size: 50 * GB) == .unknown)
        #expect(MovieClassifier.classify(width: 0, height: 0, codec: "hevc", size: 50 * GB) == .unknown)
    }

    @Test("4K remux: remux-grade codec at/above the size floor")
    func uhdRemux() {
        #expect(MovieClassifier.classify(width: 3840, height: 2160, codec: "hevc", size: 60 * GB) == .uhdRemux)
    }

    @Test("4K below the remux size floor is an encode")
    func uhdEncodeBySize() {
        #expect(MovieClassifier.classify(width: 3840, height: 2160, codec: "hevc", size: 10 * GB) == .uhdEncode)
    }

    @Test("4K in a non-remux codec is an encode even at huge sizes")
    func uhdEncodeByCodec() {
        #expect(MovieClassifier.classify(width: 3840, height: 2160, codec: "av1", size: 60 * GB) == .uhdEncode)
    }

    @Test("1080p remux vs encode hinges on the size floor")
    func bluRayRemuxVsEncode() {
        #expect(MovieClassifier.classify(width: 1920, height: 1080, codec: "h264", size: 20 * GB) == .bluRayRemux)
        #expect(MovieClassifier.classify(width: 1920, height: 1080, codec: "h264", size: 5 * GB) == .fullHDEncode)
    }

    @Test("720p and SD buckets")
    func lowerResolutions() {
        #expect(MovieClassifier.classify(width: 1280, height: 720, codec: "h264", size: 4 * GB) == .hdEncode)
        #expect(MovieClassifier.classify(width: 640, height: 480, codec: "h264", size: 1 * GB) == .sd)
    }

    @Test("Width drives the bucket for cinemascope (short) frames")
    func cinemascopeUsesLongSide() {
        // 1920x800 scope frame is still 1080p territory by long side.
        #expect(MovieClassifier.classify(width: 1920, height: 800, codec: "av1", size: 3 * GB) == .fullHDEncode)
    }

    @Test("Codec comparison is case-insensitive")
    func codecCaseInsensitive() {
        #expect(MovieClassifier.classify(width: 3840, height: 2160, codec: "HEVC", size: 60 * GB) == .uhdRemux)
    }
}
