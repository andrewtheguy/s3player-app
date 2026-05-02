//
//  APIClient.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import Foundation

enum APIError: Error, LocalizedError {
    case invalidHost
    case unauthorized
    case notFound
    case upstreamFailure
    case http(Int)
    case transport(URLError)
    case decoding(DecodingError)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid host."
        case .unauthorized: return "Session expired. Please sign in again."
        case .notFound: return "Not found."
        case .upstreamFailure: return "Upstream service is unavailable."
        case .http(let code): return "Request failed (HTTP \(code))."
        case .transport(let error): return error.localizedDescription
        case .decoding: return "Could not parse server response."
        }
    }
}

struct APIClient {
    let host: URL
    let token: String
    var session: URLSession = .shared
    var decoder: JSONDecoder = CatalogDecoder.make()

    // Site bearer token only. The player session token (X-Player-Session) is
    // intentionally unimplemented here — this client never claims, validates,
    // or sends a player session. Do not add player session headers.

    init?(auth: AuthViewModel) {
        guard
            let hostString = auth.host,
            let url = URL(string: hostString),
            let token = auth.token
        else {
            return nil
        }
        self.host = url
        self.token = token
    }

    init(host: URL, token: String, session: URLSession = .shared) {
        self.host = host
        self.token = token
        self.session = session
    }

    func listStations() async throws -> StationsResponse {
        try await get("api/shows/stations")
    }

    func listShows(station: String) async throws -> ShowsResponse {
        let encoded = station.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? station
        return try await get("api/shows/stations/\(encoded)/shows")
    }

    func listMonths(showId: Int) async throws -> MonthsResponse {
        try await get("api/shows/\(showId)/months")
    }

    func listEpisodes(showId: Int, year: Int, month: Int) async throws -> EpisodesResponse {
        try await get("api/shows/\(showId)/months/\(year)/\(month)/episodes")
    }

    func getAudioURL(episodeId: Int) async throws -> AudioUrlResponse {
        try await get("api/shows/episodes/\(episodeId)/audio_url")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = host.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1)
        }

        switch http.statusCode {
        case 200:
            do {
                return try decoder.decode(T.self, from: data)
            } catch let error as DecodingError {
                throw APIError.decoding(error)
            }
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 502:
            throw APIError.upstreamFailure
        default:
            throw APIError.http(http.statusCode)
        }
    }
}
