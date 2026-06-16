import Testing
@testable import MovieStats

@Suite("TitleParser")
struct TitleParserTests {
    @Test("Standard scene release: title + year, encoder cruft dropped",
          arguments: [
            ("The.Matrix.1999.1080p.BluRay.x264.mkv", "The Matrix", 1999),
            ("Inception 2010 2160p UHD Remux.mkv", "Inception", 2010),
            ("Blade.Runner.2049.2017.mkv", "Blade Runner 2049", 2017),
          ])
    func standardReleases(file: String, title: String, year: Int) {
        let parsed = TitleParser.parse(filename: file)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
    }

    @Test("Leading year that isn't the release year is kept in the title")
    func titleStartingWithYear() {
        // The last valid year wins; the leading "2001" (position 0) is excluded.
        let parsed = TitleParser.parse(filename: "2001.A.Space.Odyssey.1968.mkv")
        #expect(parsed.title == "2001 A Space Odyssey")
        #expect(parsed.year == 1968)
    }

    @Test("A bare year-shaped number at position 0 with no later year => no year")
    func soleLeadingYearIsNotAYear() {
        let parsed = TitleParser.parse(filename: "2001 A Space Odyssey.mkv")
        #expect(parsed.year == nil)
        #expect(parsed.title == "2001 A Space Odyssey")
    }

    @Test("Internal punctuation in the title survives")
    func commaInTitle() {
        let parsed = TitleParser.parse(filename: "Honey, I Shrunk The Kids 1989.mkv")
        #expect(parsed.title == "Honey, I Shrunk The Kids")
        #expect(parsed.year == 1989)
    }

    @Test("No year: truncate at the first quality-marker stop word")
    func noYearStopsAtQualityMarker() {
        let parsed = TitleParser.parse(filename: "Demolition.Man.BluRay.1080p.x264.mkv")
        #expect(parsed.title == "Demolition Man")
        #expect(parsed.year == nil)
    }

    @Test("Leading release-group tags are stripped")
    func stripsLeadingTags() {
        let parsed = TitleParser.parse(filename: "[YIFY] The Italian Job 2003.mp4")
        #expect(parsed.title == "The Italian Job")
        #expect(parsed.year == 2003)
    }

    @Test("Year glued to letters/digits does not false-match",
          arguments: [
            "Edge2020.The.Movie.mkv",   // release-group + counter glued
            "Movie.1980s.Nostalgia.mkv", // 1980s is a decade, not a year
          ])
    func gluedYearsAreNotYears(file: String) {
        // None of these expose a clean flanked year, so year is nil.
        #expect(TitleParser.parse(filename: file).year == nil)
    }

    @Test("Multi-part tokens are extracted and stripped from the title",
          arguments: [
            ("Kill.Bill.2003.cd1.avi", "Kill Bill", 2003, 1),
            ("The.Movie.2011.part2.mkv", "The Movie", 2011, 2),
            ("Some Film disc 3 2009.mkv", "Some Film", 2009, 3),
          ])
    func partNumbers(file: String, title: String, year: Int, part: Int) {
        let parsed = TitleParser.parse(filename: file)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
        #expect(parsed.partNumber == part)
    }

    @Test("A literal 'Part N' in a real title is parsed as a part number")
    func literalPartInTitle() {
        let parsed = TitleParser.parse(filename: "Harry Potter and the Deathly Hallows Part 1 2010.mkv")
        #expect(parsed.partNumber == 1)
        #expect(parsed.year == 2010)
        #expect(parsed.title == "Harry Potter and the Deathly Hallows")
    }

    @Test("Hard-coded overrides for the 4k7x fan restorations",
          arguments: [
            ("4k77_NoDNR_v1.4.qsv.mkv", "4k77 Star Wars A New Hope Original Print Scan", 1977),
            ("4k80_v1.0.qsv.mkv", "4k80 Star Wars Empire Strikes Back Original Print Scan", 1980),
            ("4k83_v2.0.qsv.mkv", "4k83 Star Wars Return of the Jedi Original Print Scan", 1983),
          ])
    func overrides(file: String, title: String, year: Int) {
        let parsed = TitleParser.parse(filename: file)
        #expect(parsed.title == title)
        #expect(parsed.year == year)
        #expect(parsed.partNumber == nil)
    }

    @Test("displayName formats with and without a year")
    func displayName() {
        #expect(TitleParser.Parsed(title: "X", year: 2000).displayName == "X (2000)")
        #expect(TitleParser.Parsed(title: "X", year: nil).displayName == "X")
    }
}
