import Testing
@testable import MovieStats

@Suite("FilenameSanitizer")
struct FilenameSanitizerTests {
    @Test("Colons become ' - ' with surrounding spaces collapsed",
          arguments: [
            ("Star Wars: A New Hope", "Star Wars - A New Hope"),
            ("3:10 to Yuma", "3 - 10 to Yuma"),
          ])
    func colonHandling(input: String, expected: String) {
        #expect(FilenameSanitizer.sanitize(input) == expected)
    }

    @Test("Path separators become hyphens; Windows-illegal chars are stripped")
    func illegalChars() {
        #expect(FilenameSanitizer.sanitize("A/B\\C") == "A-B-C")
        #expect(FilenameSanitizer.sanitize("What?*<>|\"Now") == "WhatNow")
    }

    @Test("Trailing dots/spaces and collapsed whitespace are cleaned")
    func trailingAndWhitespace() {
        #expect(FilenameSanitizer.sanitize("Movie.  ") == "Movie")
        #expect(FilenameSanitizer.sanitize("A   B") == "A B")
    }

    @Test("Diacritics and non-Latin scripts are preserved")
    func unicodePreserved() {
        #expect(FilenameSanitizer.sanitize("Amélie") == "Amélie")
        #expect(FilenameSanitizer.sanitize("千と千尋の神隠し") == "千と千尋の神隠し")
    }

    @Test("Length is capped at maxBaseLength")
    func lengthCap() {
        let long = String(repeating: "a", count: 500)
        #expect(FilenameSanitizer.sanitize(long).count == FilenameSanitizer.maxBaseLength)
    }

    @Test("folderName composes Title (Year) {tmdb-N}, year optional")
    func folderName() {
        #expect(FilenameSanitizer.folderName(title: "The Matrix", year: 1999, tmdbID: 603)
                == "The Matrix (1999) {tmdb-603}")
        #expect(FilenameSanitizer.folderName(title: "Untitled", year: nil, tmdbID: 7)
                == "Untitled {tmdb-7}")
    }

    @Test("fileBasename appends edition, quality tag, and part suffix in order")
    func fileBasenameComposition() {
        let base = FilenameSanitizer.fileBasename(
            title: "The Matrix", year: 1999, tmdbID: 603,
            customEdition: "Director's Cut", qualityTag: "4K Remux", partNumber: 1
        )
        #expect(base == "The Matrix (1999) {tmdb-603} {edition-Director's Cut} [4K Remux] - pt1")
    }

    @Test("fileBasename omits an empty/whitespace edition block")
    func emptyEditionDropped() {
        let base = FilenameSanitizer.fileBasename(
            title: "X", year: 2000, tmdbID: 1, customEdition: "   "
        )
        #expect(base == "X (2000) {tmdb-1}")
    }

    @Test("qualityTag composes resolution + HDR/DV + Remux",
          arguments: [
            // width, height, remux, hdr, dv, expected
            (3840, 2160, true, String?.none, false, "4K Remux"),
            (1920, 1080, false, String?.none, false, "1080p"),
            (3840, 2160, false, String?.some("HDR10"), false, "4K HDR"),
            (3840, 2160, false, String?.some("HDR10"), true, "4K DV"), // DV wins over HDR
            (1280, 720, false, String?.none, false, "720p"),
          ])
    func qualityTag(width: Int, height: Int, remux: Bool, hdr: String?, dv: Bool, expected: String) {
        #expect(FilenameSanitizer.qualityTag(
            width: width, height: height, isRemux: remux, hdrFormat: hdr, hasDolbyVision: dv
        ) == expected)
    }

    @Test("qualityTag returns 'Unknown' (resolution) when unprobed")
    func qualityTagUnknown() {
        let tag = FilenameSanitizer.qualityTag(
            width: nil, height: nil, isRemux: false, hdrFormat: nil, hasDolbyVision: false
        )
        #expect(tag == "Unknown")
    }

    @Test("hasSpecialCharacters flags anything the sanitizer would rewrite",
          arguments: [
            ("a:b", true), ("a/b", true), ("a  b", true), ("trailing ", true),
            ("trailing.", true), ("clean name", false),
          ])
    func hasSpecialCharacters(input: String, flagged: Bool) {
        #expect(FilenameSanitizer.hasSpecialCharacters(input) == flagged)
    }

    @Test("containsRemux is a case-insensitive substring scan",
          arguments: [
            ("Movie.2020.UHD.Remux.HEVC.mkv", true),
            ("movie.remux.mkv", true),
            ("Movie.1080p.BluRay.mkv", false),
          ])
    func containsRemux(input: String, expected: Bool) {
        #expect(FilenameSanitizer.containsRemux(input) == expected)
    }
}
