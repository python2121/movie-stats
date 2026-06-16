import Testing
@testable import MovieStats

@Suite("SubtitleClassifier")
struct SubtitleClassifierTests {
    @Test("Subtitle extension recognition is case-insensitive",
          arguments: [
            ("srt", true), ("SRT", true), ("ass", true), ("idx", true),
            ("sub", true), ("sup", true), ("mkv", false), ("txt", false),
          ])
    func extensionRecognition(ext: String, isSub: Bool) {
        #expect(SubtitleClassifier.isSubtitleExtension(ext) == isSub)
    }

    @Test("Subtitle folder aliases: exact short forms + prefix-with-boundary",
          arguments: [
            ("Subs", true),
            ("subtitles", true),
            ("s", true),                              // exact short alias
            ("Subtitles Eng [SubRip - MicroDVD]", true), // prefix + boundary
            ("Subtitle,info", true),
            ("Subway", false),                        // boundary guard
            ("Some", false),                          // 's' must be exact
            ("Movie", false),
          ])
    func folderAliases(name: String, isAlias: Bool) {
        #expect(SubtitleClassifier.isSubtitleFolderAlias(name) == isAlias)
    }

    @Test("parse extracts language code")
    func parseLanguage() {
        let p = SubtitleClassifier.parse(filename: "Movie.eng.srt")
        #expect(p.lang == "en")
        #expect(p.forced == false)
        #expect(p.sdh == false)
        #expect(p.descriptor == nil)
    }

    @Test("parse extracts forced + sdh flags")
    func parseFlags() {
        let p = SubtitleClassifier.parse(filename: "Movie.en.forced.srt")
        #expect(p.forced == true)
        let q = SubtitleClassifier.parse(filename: "Movie.en.sdh.srt")
        #expect(q.sdh == true)
    }

    @Test("Multi-token 'Hearing Impaired' is detected as SDH",
          arguments: [
            "Movie.Hearing.Impaired.eng.srt",
            "Movie.Hearing_Impaired.eng.srt",
            "Movie.Hearing-Impaired.eng.srt",
          ])
    func multiTokenSDH(file: String) {
        #expect(SubtitleClassifier.parse(filename: file).sdh == true)
    }

    @Test("'hi' is neither SDH nor matched as a language (ISO ambiguity)")
    func hiIsNotSDH() {
        let p = SubtitleClassifier.parse(filename: "Movie.hi.srt")
        #expect(p.sdh == false)
        #expect(p.lang == nil)
    }

    @Test("parse extracts a descriptor that distinguishes same-language tracks")
    func parseDescriptor() {
        let p = SubtitleClassifier.parse(filename: "Movie.commentary.eng.srt")
        #expect(p.descriptor == "commentary")
        #expect(p.lang == "en")
    }

    @Test("compose drops unset segments and orders lang → descriptor → flags")
    func compose() {
        #expect(SubtitleClassifier.compose(
            base: "M", lang: "en", forced: false, sdh: false, descriptor: nil, ext: "srt"
        ) == "M.en.srt")
        #expect(SubtitleClassifier.compose(
            base: "M", lang: "en", forced: true, sdh: true, descriptor: "commentary", ext: "srt"
        ) == "M.en.commentary.sdh.forced.srt")
        #expect(SubtitleClassifier.compose(
            base: "M", lang: nil, forced: false, sdh: false, descriptor: nil, ext: "srt"
        ) == "M.srt")
    }

    @Test("compose re-emits a numeric collision suffix; empty ext adds no dot")
    func composeSuffixAndNoExt() {
        #expect(SubtitleClassifier.compose(
            base: "M", lang: "en", forced: false, sdh: false, descriptor: nil,
            numericSuffix: 2, ext: "srt"
        ) == "M.en.2.srt")
        #expect(SubtitleClassifier.compose(
            base: "M", lang: "en", forced: false, sdh: false, descriptor: nil, ext: ""
        ) == "M.en")
    }

    @Test("extractNumericSuffix only recognizes a trailing .N where N >= 2",
          arguments: [
            ("Movie.en.2.srt", 2),
            ("Movie.en.10.srt", 10),
            ("Movie.en.srt", nil),   // trailing token isn't numeric
            ("Movie.en.1.srt", nil), // .1 is never handed out
          ])
    func extractNumericSuffix(file: String, expected: Int?) {
        #expect(SubtitleClassifier.extractNumericSuffix(filename: file) == expected)
    }

    @Test("Round-trip: parse then compose yields a canonical sidecar name")
    func roundTrip() {
        let p = SubtitleClassifier.parse(filename: "Some.Release.commentary.eng.forced.srt")
        let composed = SubtitleClassifier.compose(
            base: "Movie (2000) {tmdb-1}",
            lang: p.lang, forced: p.forced, sdh: p.sdh, descriptor: p.descriptor, ext: "srt"
        )
        #expect(composed == "Movie (2000) {tmdb-1}.en.commentary.forced.srt")
    }
}
