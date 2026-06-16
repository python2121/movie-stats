import Foundation
import Testing
@testable import MovieStats

@Suite("TMDB preferredReleaseDate")
struct TMDBReleaseDateTests {
    private func detail(from json: String) throws -> TMDBMovieDetail {
        try JSONDecoder().decode(TMDBMovieDetail.self, from: Data(json.utf8))
    }

    @Test("Earliest premiere/theatrical across countries wins over release_date")
    func earliestTheatricalWins() throws {
        // release_date is the 1998 wide release; a 1997 festival premiere exists.
        let d = try detail(from: """
        {
          "id": 10494, "title": "Perfect Blue",
          "release_date": "1998-02-28",
          "release_dates": { "results": [
            { "iso_3166_1": "JP", "release_dates": [
              { "type": 3, "release_date": "1998-02-28" }
            ]},
            { "iso_3166_1": "US", "release_dates": [
              { "type": 1, "release_date": "1997-08-15" }
            ]}
          ]}
        }
        """)
        #expect(d.preferredReleaseDate == "1997-08-15")
        #expect(d.year == "1997")
    }

    @Test("Digital/Physical/TV release types are ignored; falls back to release_date")
    func skipsNonTheatricalTypes() throws {
        let d = try detail(from: """
        {
          "id": 1, "title": "Direct To Streaming",
          "release_date": "2000-01-01",
          "release_dates": { "results": [
            { "iso_3166_1": "US", "release_dates": [
              { "type": 4, "release_date": "1999-06-01" },
              { "type": 5, "release_date": "1999-09-01" }
            ]}
          ]}
        }
        """)
        // No theatrical/premiere entry => fall back to top-level release_date.
        #expect(d.preferredReleaseDate == "2000-01-01")
        #expect(d.year == "2000")
    }

    @Test("No per-country data falls back to release_date")
    func fallbackWhenNoReleaseDates() throws {
        let d = try detail(from: #"{ "id": 2, "title": "Sparse", "release_date": "1995-05-05" }"#)
        #expect(d.preferredReleaseDate == "1995-05-05")
        #expect(d.year == "1995")
    }

    @Test("No date information at all yields nil year")
    func noDates() throws {
        let d = try detail(from: #"{ "id": 3, "title": "Mystery" }"#)
        #expect(d.preferredReleaseDate == nil)
        #expect(d.year == nil)
    }

    @Test("Static helper agrees with the computed property")
    func staticHelperMatches() throws {
        let d = try detail(from: """
        {
          "id": 4, "title": "X", "release_date": "2010-12-01",
          "release_dates": { "results": [
            { "iso_3166_1": "FR", "release_dates": [
              { "type": 2, "release_date": "2010-05-10" }
            ]}
          ]}
        }
        """)
        let viaStatic = TMDBMovieDetail.preferredReleaseDate(
            releaseDates: d.releaseDates, releaseDate: d.releaseDate
        )
        #expect(viaStatic == d.preferredReleaseDate)
        #expect(viaStatic == "2010-05-10")
    }
}
