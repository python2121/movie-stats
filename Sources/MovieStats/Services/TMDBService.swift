import Foundation

/// One movie row returned by TMDB's `search/movie` endpoint. Only fields we
/// actually display are decoded — easy to grow later.
struct TMDBMovie: Decodable, Sendable, Hashable {
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
}

/// Tiny URLSession-based wrapper around TMDB's v3 search endpoint. Supports
/// either auth style transparently — a long bearer-style v4 token goes in the
/// Authorization header, a 32-char v3 API key goes in the query string.
enum TMDBService {
    static let apiKeyDefaultsKey = "tmdbAPIKey"

    enum TMDBError: Error, LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case decode
        case noResults

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

    /// Searches TMDB for the best match for `title` + optional `year`. Returns
    /// the first result (TMDB sorts by relevance/popularity by default).
    static func searchMovie(title: String, year: Int?) async throws -> TMDBMovie {
        guard let key = apiKey else { throw TMDBError.missingAPIKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false"),
            URLQueryItem(name: "language", value: "en-US"),
        ]
        if let year {
            items.append(URLQueryItem(name: "primary_release_year", value: String(year)))
        }

        var request: URLRequest
        if isBearerToken(key) {
            components.queryItems = items
            request = URLRequest(url: components.url!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            items.append(URLQueryItem(name: "api_key", value: key))
            components.queryItems = items
            request = URLRequest(url: components.url!)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.decode }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw TMDBError.http(http.statusCode, bodyString)
        }

        struct SearchResponse: Decodable { let results: [TMDBMovie] }
        guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
            throw TMDBError.decode
        }
        guard let first = decoded.results.first else { throw TMDBError.noResults }
        return first
    }

    /// V4 bearer tokens are JWTs (header.payload.signature) and run to ~200
    /// chars; v3 keys are 32-char hex. Crude but reliable detection.
    private static func isBearerToken(_ key: String) -> Bool {
        key.contains(".") && key.count > 100
    }
}
