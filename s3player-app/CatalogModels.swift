//
//  CatalogModels.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import Foundation

struct Station: Decodable, Hashable, Identifiable {
    let id: String
    let show_count: Int
}

struct StationsResponse: Decodable {
    let stations: [Station]
}

struct Show: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let episode_count: Int
}

struct ShowsResponse: Decodable {
    let shows: [Show]
}

struct ShowDetail: Codable, Hashable, Identifiable {
    let id: Int
    let station: String
    let name: String
    let episode_count: Int
}

struct MonthBucket: Decodable, Hashable {
    let year: Int
    let month: Int
    let episode_count: Int
}

struct MonthsResponse: Decodable {
    let show: ShowDetail
    let months: [MonthBucket]
}

struct Chapter: Codable, Hashable {
    let title: String
    let start: Int
    let end: Int
}

struct Episode: Codable, Hashable, Identifiable {
    let id: Int
    let aired_on: Date
    let time_slot: String?
    let s3_key: String
    let chapters: [Chapter]?
}

struct EpisodeDetail: Codable, Hashable, Identifiable {
    let id: Int
    let aired_on: Date
    let time_slot: String?
    let s3_key: String
    let chapters: [Chapter]?
    let show: ShowDetail

    var episode: Episode {
        Episode(
            id: id,
            aired_on: aired_on,
            time_slot: time_slot,
            s3_key: s3_key,
            chapters: chapters
        )
    }
}

struct EpisodesResponse: Decodable {
    let show: ShowDetail
    let episodes: [Episode]
}

struct ClaimResponse: Decodable {
    let session_token: String
}

struct ProgressRequest: Encodable {
    let position_ms: Int
    let duration_ms: Int?
    let completed: Bool
}

struct ProgressResponse: Codable, Hashable {
    let position_ms: Int
    let duration_ms: Int?
    let completed: Bool
    let last_played_at: String?
}

struct RecentEpisode: Decodable, Hashable, Identifiable {
    let id: Int
    let aired_on: Date
    let time_slot: String?
    let show_id: Int
    let show_name: String
    let station: String
    let position_ms: Int
    let duration_ms: Int?
    let last_played_at: String
}

struct RecentResponse: Decodable {
    let episodes: [RecentEpisode]
}

enum CatalogDecoder {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(dateFormatter)
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(dateFormatter)
        return encoder
    }
}

func formatTimeSlot(_ slot: String?) -> String {
    guard let slot, !slot.isEmpty else { return "" }
    let pattern = #"^(\d{2})(\d{2})_(\d{2})(\d{2})$"#
    guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: slot, range: NSRange(slot.startIndex..., in: slot)),
        match.numberOfRanges == 5
    else {
        return slot
    }

    func part(_ index: Int) -> String {
        guard
            let range = Range(match.range(at: index), in: slot)
        else { return "" }
        return String(slot[range])
    }

    return "\(part(1)):\(part(2))–\(part(3)):\(part(4))"
}
