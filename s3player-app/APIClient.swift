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
    case sessionDisplaced
    case notFound
    case upstreamFailure
    case http(Int)
    case transport(URLError)
    case decoding(DecodingError)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid host."
        case .unauthorized: return "Session expired. Please sign in again."
        case .sessionDisplaced: return "Another device took over playback."
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

    // Authorization: Bearer <site-token> is attached to every /api/* request.
    // X-Player-Session is attached only to player-session-protected endpoints
    // (validateSession, saveProgress) — never to browse, audio_url, or login.

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

    func getProgress(episodeId: Int) async throws -> ProgressResponse {
        try await get("api/player/episodes/\(episodeId)/progress")
    }

    func claimSession() async throws -> ClaimResponse {
        try await post("api/player/session/claim", body: Optional<Empty>.none, playerSessionToken: nil)
    }

    func validateSession(playerToken: String) async throws {
        let _: EmptyResponse = try await post(
            "api/player/session/validate",
            body: Optional<Empty>.none,
            playerSessionToken: playerToken
        )
    }

    func saveProgress(
        episodeId: Int,
        playerToken: String,
        positionMs: Int,
        durationMs: Int?
    ) async throws {
        let _: EmptyResponse = try await post(
            "api/player/episodes/\(episodeId)/progress",
            body: ProgressRequest(position_ms: positionMs, duration_ms: durationMs),
            playerSessionToken: playerToken
        )
    }

    func markComplete(episodeId: Int, playerToken: String) async throws {
        let _: EmptyResponse = try await post(
            "api/player/episodes/\(episodeId)/complete",
            body: Optional<Empty>.none,
            playerSessionToken: playerToken
        )
    }

    private struct Empty: Encodable {}
    private struct EmptyResponse: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = makeRequest(path: path, method: "GET", body: Optional<Empty>.none, playerSessionToken: nil)
        return try await execute(request)
    }

    private func post<Body: Encodable, T: Decodable>(
        _ path: String,
        body: Body?,
        playerSessionToken: String?
    ) async throws -> T {
        let request = makeRequest(path: path, method: "POST", body: body, playerSessionToken: playerSessionToken)
        return try await execute(request)
    }

    private func makeRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        playerSessionToken: String?
    ) -> URLRequest {
        let url = host.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let playerSessionToken {
            request.setValue(playerSessionToken, forHTTPHeaderField: "X-Player-Session")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
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
            if T.self == EmptyResponse.self || data.isEmpty {
                return try decoder.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch let error as DecodingError {
                throw APIError.decoding(error)
            }
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.sessionDisplaced
        case 502:
            throw APIError.upstreamFailure
        default:
            throw APIError.http(http.statusCode)
        }
    }
}
