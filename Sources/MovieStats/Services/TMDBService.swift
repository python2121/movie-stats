import Foundation

// MARK: - Search result row

/// One movie row returned by TMDB's `search/movie` endpoint. Slim — enough to
/// show in the matcher table and the manual-pick sheet.
struct TMDBMovie: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let title: String
    let originalTitle: String?
    let releaseDate: String?
    let overview: String?
    let voteAverage: Double?
    let voteCount: Int?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case posterPath = "poster_path"
    }

    var year: String? {
        guard let date = releaseDate, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    var displayTitle: String {
        if let year { return "\(title) (\(year))" }
        return title
    }
}

// MARK: - Full detail rows (everything we persist)

struct TMDBGenre: Codable, Sendable, Hashable {
    let id: Int
    let name: String
}

struct TMDBCompany: Codable, Sendable, Hashable {
    let id: Int
    let name: String
    let logoPath: String?
    let originCountry: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case logoPath = "logo_path"
        case originCountry = "origin_country"
    }
}

struct TMDBCountry: Codable, Sendable, Hashable {
    let iso31661: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case name
    }
}

struct TMDBLanguage: Codable, Sendable, Hashable {
    let iso6391: String
    let name: String
    let englishName: String?

    enum CodingKeys: String, CodingKey {
        case iso6391 = "iso_639_1"
        case name
        case englishName = "english_name"
    }
}

struct TMDBCollection: Codable, Sendable, Hashable {
    let id: Int
    let name: String
    let posterPath: String?
    let backdropPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }
}

// MARK: - Per-country release dates

/// One entry in `/movie/{id}/release_dates`'s nested `release_dates` array.
/// `type` codes: 1=Premiere, 2=Theatrical limited, 3=Theatrical, 4=Digital,
/// 5=Physical, 6=TV.
struct TMDBReleaseDate: Codable, Sendable, Hashable {
    let certification: String?
    let iso6391: String?
    let note: String?
    let releaseDate: String?
    let type: Int?

    enum CodingKeys: String, CodingKey {
        case certification, note, type
        case iso6391 = "iso_639_1"
        case releaseDate = "release_date"
    }
}

struct TMDBReleaseDateGroup: Codable, Sendable, Hashable {
    let iso31661: String
    let releaseDates: [TMDBReleaseDate]

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

/// Top-level shape returned by `append_to_response=release_dates`. Wrapped in
/// a `results` array keyed by country.
struct TMDBReleaseDates: Codable, Sendable, Hashable {
    let results: [TMDBReleaseDateGroup]
}

/// Full /movie/{id} response. Everything optional except `id` and `title`
/// because TMDB is loose about which fields it returns for sparser titles.
struct TMDBMovieDetail: Codable, Sendable, Hashable {
    let id: Int
    let imdbID: String?
    let title: String
    let originalTitle: String?
    let originalLanguage: String?
    let tagline: String?
    let overview: String?
    let releaseDate: String?
    let runtime: Int?
    let status: String?
    let budget: Int?
    let revenue: Int?
    let popularity: Double?
    let voteAverage: Double?
    let voteCount: Int?
    let adult: Bool?
    let video: Bool?
    let backdropPath: String?
    let posterPath: String?
    let homepage: String?
    let genres: [TMDBGenre]?
    let productionCompanies: [TMDBCompany]?
    let productionCountries: [TMDBCountry]?
    let spokenLanguages: [TMDBLanguage]?
    let belongsToCollection: TMDBCollection?
    /// Per-country release dates from `append_to_response=release_dates` — lets
    /// us pick the US theatrical release year instead of TMDB's
    /// country-of-origin `release_date`, which is often a festival premiere
    /// a year earlier for foreign films.
    let releaseDates: TMDBReleaseDates?

    enum CodingKeys: String, CodingKey {
        case id, title, tagline, overview, runtime, status, budget, revenue
        case popularity, adult, video, homepage, genres
        case imdbID = "imdb_id"
        case originalTitle = "original_title"
        case originalLanguage = "original_language"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case backdropPath = "backdrop_path"
        case posterPath = "poster_path"
        case productionCompanies = "production_companies"
        case productionCountries = "production_countries"
        case spokenLanguages = "spoken_languages"
        case belongsToCollection = "belongs_to_collection"
        case releaseDates = "release_dates"
    }

    /// The most user-meaningful release date for this title — the earliest
    /// premiere / theatrical-limited / theatrical entry across all
    /// countries, matching IMDb's "first known release year" convention
    /// (films like Miracle Mile and Perfect Blue are catalogued by their
    /// festival-premiere year, not the wide release). Falls back to TMDB's
    /// top-level `release_date` when no per-country data is available.
    ///
    /// Skips Digital (4), Physical (5), and TV (6) — those don't move the
    /// canonical "year of release" needle.
    var preferredReleaseDate: String? {
        Self.preferredReleaseDate(releaseDates: releaseDates, releaseDate: releaseDate)
    }

    /// Static counterpart usable from places that only have the raw
    /// columns (notably `MovieStore.makeMovie` where the main library
    /// list query JOINs onto `tmdb_movies` and we want to derive the
    /// canonical year for display without rebuilding a full
    /// `TMDBMovieDetail`).
    static func preferredReleaseDate(
        releaseDates: TMDBReleaseDates?,
        releaseDate: String?
    ) -> String? {
        // Types: 1=Premiere, 2=Theatrical (limited), 3=Theatrical.
        let theatricalTypes: Set<Int> = [1, 2, 3]
        var earliest: String?
        for group in releaseDates?.results ?? [] {
            for entry in group.releaseDates {
                guard let type = entry.type, theatricalTypes.contains(type),
                      let date = entry.releaseDate, !date.isEmpty
                else { continue }
                // YYYY-MM-DD sorts lexicographically the same as chronologically.
                if earliest == nil || date < earliest! { earliest = date }
            }
        }
        return earliest ?? releaseDate
    }

    var year: String? {
        let source = preferredReleaseDate ?? releaseDate
        guard let date = source, date.count >= 4 else { return nil }
        return String(date.prefix(4))
    }

    var displayTitle: String {
        if let year { return "\(title) (\(year))" }
        return title
    }
}

// MARK: - Videos (trailers)

struct TMDBVideo: Decodable, Sendable, Hashable {
    let key: String
    let site: String
    let type: String
    let name: String
    let official: Bool?

    var youtubeURL: URL? {
        guard site.lowercased() == "youtube" else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
}

// MARK: - Collection detail

/// `/collection/{id}` response — the franchise and every movie in it.
struct TMDBCollectionDetail: Decodable, Sendable, Hashable {
    let id: Int
    let name: String
    let overview: String?
    let posterPath: String?
    let parts: [TMDBMovie]

    enum CodingKeys: String, CodingKey {
        case id, name, overview, parts
        case posterPath = "poster_path"
    }
}

// MARK: - Service

/// Tiny URLSession-based wrapper around TMDB's v3 API. Supports either auth
/// style transparently — a long bearer-style v4 token goes in the
/// Authorization header, a 32-char v3 API key goes in the query string.
enum TMDBService {
    static let apiKeyDefaultsKey = "tmdbAPIKey"
    /// Base URL for poster/backdrop thumbnails. Most TMDB clients use w500
    /// for poster cards — good quality without huge bytes.
    static let imageBaseURL = "https://image.tmdb.org/t/p/w500"
    /// Higher-resolution version for the detail view.
    static let imageOriginalURL = "https://image.tmdb.org/t/p/original"

    enum TMDBError: Error, LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case decode
        case noResults
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No TMDB API key configured."
            case .http(let code, let body):
                return body.isEmpty ? "TMDB HTTP \(code)" : "TMDB HTTP \(code): \(body)"
            case .decode:
                return "Couldn't decode TMDB response."
            case .noResults:
                return "No matches found."
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    static var apiKey: String? {
        let raw = UserDefaults.standard.string(forKey: apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static func setAPIKey(_ key: String) {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            UserDefaults.standard.removeObject(forKey: apiKeyDefaultsKey)
        } else {
            UserDefaults.standard.set(cleaned, forKey: apiKeyDefaultsKey)
        }
    }

    /// Returns the first search hit for `title` + `year`. Convenience wrapper
    /// around `searchMovies` for callers that just want the best guess.
    static func searchMovie(title: String, year: Int?) async throws -> TMDBMovie {
        let results = try await searchMovies(title: title, year: year)
        guard let first = results.first else { throw TMDBError.noResults }
        return first
    }

    /// Extracts a `{tmdb-N}` tag embedded in a filesystem path — the
    /// canonical format the renamer writes into every wrapper folder
    /// and filename. Used by the matcher to bypass title-based search
    /// entirely when the source path already carries an explicit ID
    /// (much more reliable than the fuzzy lookup, and sidesteps the
    /// diacritic quirk in TMDB's search backend).
    ///
    /// Returns nil if the path doesn't carry the tag. The match is
    /// case-insensitive on the `tmdb` prefix to forgive odd variants.
    static func tmdbID(fromPath path: String) -> Int? {
        let pattern = #"\{[tT][mM][dD][bB]-(\d+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(path.startIndex..., in: path)
        guard let match = regex.firstMatch(in: path, range: range),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: path)
        else { return nil }
        return Int(path[captured])
    }

    /// Full list of search results, ordered as TMDB returns them (relevance /
    /// popularity). Used by the matcher's "pick a different result" sheet.
    ///
    /// If the first query returns nothing and the title contains
    /// diacritics, retries with the diacritics stripped. TMDB's search
    /// backend is inconsistent here: a query like `Le Samouraï` returns
    /// zero results, while `Le Samourai` matches the canonical
    /// `Le Samouraï` record fine. The retry preserves the user's
    /// original input as-is for titles where TMDB handles diacritics
    /// correctly, and falls back transparently for the ones where it
    /// doesn't.
    static func searchMovies(title: String, year: Int?) async throws -> [TMDBMovie] {
        let results = try await rawSearch(title: title, year: year)
        if !results.isEmpty { return results }
        let stripped = title.folding(options: .diacriticInsensitive, locale: nil)
        guard stripped != title else { return results }
        return try await rawSearch(title: stripped, year: year)
    }

    private static func rawSearch(title: String, year: Int?) async throws -> [TMDBMovie] {
        guard let key = apiKey else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
        ]
        if let year {
            // `year` matches *any* release year, not just primary — important
            // because TMDB's primary year is the country-of-origin release,
            // which can be a year earlier than the US/wide release that the
            // filenames in this app typically encode.
            items.append(URLQueryItem(name: "year", value: String(year)))
        }

        let request = makeRequest(components: &components, items: items, key: key)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)

        struct SearchResponse: Decodable { let results: [TMDBMovie] }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw TMDBError.decode
        }
        return decoded.results
    }

    /// Fetches the full `/movie/{id}` payload — needed before persisting a
    /// match so we capture genres / production info / collection / etc.
    static func details(forID id: Int) async throws -> TMDBMovieDetail {
        guard let key = apiKey else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(id)")!
        let items: [URLQueryItem] = [
            URLQueryItem(name: "language", value: "en-US"),
            // Free piggy-back in the same request — used to derive the
            // displayed year (preferring US theatrical) and persisted so the
            // detail sheet doesn't need a re-fetch.
            URLQueryItem(name: "append_to_response", value: "release_dates"),
        ]
        let request = makeRequest(components: &components, items: items, key: key)

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)

        guard let decoded = try? JSONDecoder().decode(TMDBMovieDetail.self, from: data) else {
            throw TMDBError.decode
        }
        return decoded
    }

    /// Best YouTube trailer for a movie: official trailers first, then any
    /// trailer, then a teaser. Nil when TMDB has no usable video.
    static func trailer(forID id: Int) async throws -> TMDBVideo? {
        guard let key = apiKey else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(id)/videos")!
        let request = makeRequest(
            components: &components,
            items: [URLQueryItem(name: "language", value: "en-US")],
            key: key
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)

        struct VideosResponse: Decodable { let results: [TMDBVideo] }
        guard let decoded = try? JSONDecoder().decode(VideosResponse.self, from: data) else {
            throw TMDBError.decode
        }
        let youtube = decoded.results.filter { $0.youtubeURL != nil }
        let trailers = youtube.filter { $0.type.lowercased() == "trailer" }
        return trailers.first { $0.official == true }
            ?? trailers.first
            ?? youtube.first { $0.type.lowercased() == "teaser" }
    }

    /// Full `/collection/{id}` payload — every movie in a franchise. Used by
    /// the Collections window to find what's missing from the library.
    static func collection(forID id: Int) async throws -> TMDBCollectionDetail {
        guard let key = apiKey else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/collection/\(id)")!
        let request = makeRequest(
            components: &components,
            items: [URLQueryItem(name: "language", value: "en-US")],
            key: key
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response: response, data: data)

        guard let decoded = try? JSONDecoder().decode(TMDBCollectionDetail.self, from: data) else {
            throw TMDBError.decode
        }
        return decoded
    }

    /// Downloads the bytes for a poster path (e.g. `/abc.jpg`) at the
    /// caller-chosen size. `nil` if the path is empty.
    static func downloadImage(path: String?, base: String = imageBaseURL) async throws -> Data? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(string: base + path)!
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response: response, data: data)
        return data
    }

    // MARK: - Request helpers

    private static func makeRequest(
        components: inout URLComponents,
        items: [URLQueryItem],
        key: String
    ) -> URLRequest {
        var allItems = items
        var request: URLRequest
        if isBearerToken(key) {
            components.queryItems = allItems
            request = URLRequest(url: components.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            allItems.append(URLQueryItem(name: "api_key", value: key))
            components.queryItems = allItems
            request = URLRequest(url: components.url!)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw TMDBError.decode }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw TMDBError.http(http.statusCode, body)
        }
    }

    /// V4 bearer tokens are JWTs (header.payload.signature) and run to ~200
    /// chars; v3 keys are 32-char hex. Crude but reliable detection.
    private static func isBearerToken(_ key: String) -> Bool {
        key.contains(".") && key.count > 100
    }
}
