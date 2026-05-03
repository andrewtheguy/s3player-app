//
//  PlaybackSnapshotStore.swift
//  s3player-app
//
//  Created by it3 on 5/2/26.
//

import Foundation

struct PlaybackSnapshot: Codable, Hashable {
    var episode: Episode
    var show: ShowDetail
    var chapters: [Chapter]
    var progress: ProgressResponse
    var downloadedFileExtension: String?
    var updatedAt: Date
}

struct PendingProgressEntry: Codable, Hashable {
    let episodeId: Int
    let positionMs: Int
    let durationMs: Int?
    let completed: Bool
    let recordedAt: Date
}

@MainActor
final class PlaybackSnapshotStore {
    private struct Envelope: Codable {
        let version: Int
        let payload: PlaybackSnapshot
    }

    private static let currentVersion = 1
    private let fileURL: URL
    // Snapshot dates include `updatedAt` (a full timestamp) alongside
    // `Episode.aired_on` (date-only). Use ISO 8601 so the timestamp survives
    // the round-trip; `aired_on` becomes a midnight-UTC instant on disk, which
    // is internal-only and harmless.
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.fileURL = support.appendingPathComponent("playback-snapshot.json", isDirectory: false)
    }

    func load() -> PlaybackSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == Self.currentVersion else { return nil }
            return envelope.payload
        } catch {
            // Corrupt or schema-mismatched on-disk snapshot. Don't crash; the
            // user's audio is still on disk and the next play will rebuild it.
            return nil
        }
    }

    func save(_ snapshot: PlaybackSnapshot) throws {
        let envelope = Envelope(version: Self.currentVersion, payload: snapshot)
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }
}

@MainActor
final class PendingProgressStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var entries: [PendingProgressEntry] = []

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.fileURL = support.appendingPathComponent("pending-progress.json", isDirectory: false)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func append(_ entry: PendingProgressEntry) {
        // Keep the queue compact: only the most-recent entry per episodeId
        // matters because the server upserts.
        entries.removeAll { $0.episodeId == entry.episodeId }
        entries.append(entry)
        persist()
    }

    /// Returns the latest entry per episode (most recent wins). Order is by
    /// `recordedAt` ascending so the oldest pending episode is flushed first.
    func snapshotForFlush() -> [PendingProgressEntry] {
        var latest: [Int: PendingProgressEntry] = [:]
        for entry in entries {
            if let existing = latest[entry.episodeId], existing.recordedAt >= entry.recordedAt {
                continue
            }
            latest[entry.episodeId] = entry
        }
        return latest.values.sorted { $0.recordedAt < $1.recordedAt }
    }

    func remove(episodeId: Int, recordedAtOrBefore date: Date) {
        entries.removeAll { $0.episodeId == episodeId && $0.recordedAt <= date }
        persist()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? decoder.decode([PendingProgressEntry].self, from: data) {
            entries = decoded
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
