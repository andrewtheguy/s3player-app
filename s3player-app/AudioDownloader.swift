//
//  AudioDownloader.swift
//  s3player-app
//
//  Created by it3 on 5/2/26.
//

import Foundation

@MainActor
final class AudioDownloader: NSObject {
    enum DownloadError: Error, LocalizedError {
        case unauthorized
        case http(Int)
        case transport(URLError)
        case cancelled
        case fileSystem(Error)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Session expired. Please sign in again."
            case .http(let code): return "Download failed (HTTP \(code))."
            case .transport(let error): return error.localizedDescription
            case .cancelled: return "Download cancelled."
            case .fileSystem(let error): return "File error: \(error.localizedDescription)"
            }
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Per plan: download on any connection (Wi-Fi or cellular).
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        // delegateQueue: .main is load-bearing. The URLSessionDownloadDelegate
        // callbacks below use MainActor.assumeIsolated to touch main-actor state
        // synchronously (so we can move the temp file before URLSession deletes
        // it). If you change this queue, you MUST hop to the main actor with
        // MainActor.run and accept that the temp file will be gone by then.
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private var activeTask: URLSessionDownloadTask?
    private var activeContinuation: CheckedContinuation<URL, Error>?
    private var activeEpisodeId: Int?
    private var activeProgress: ((Double) -> Void)?
    private var activeDestination: URL?

    /// Returns local file URL, downloading first if absent. If a download for a
    /// different episode is in flight, that one is cancelled before the new one starts.
    func ensureDownloaded(
        episodeId: Int,
        remoteURL: URL,
        bearerToken: String,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Single-episode cache policy: drop everything that isn't this episode.
        try? purgeAllExcept(episodeId: episodeId)

        if let cached = cachedFileURL(episodeId: episodeId) {
            progress(1.0)
            return cached
        }

        // If any download is in flight, cancel it so its awaiter unblocks before
        // we start the new one. This covers both episode-swap and same-episode
        // re-entry — callers shouldn't expect coalescing semantics in v1.
        if activeEpisodeId != nil {
            cancelActive()
        }

        let destination = try Self.destinationURL(for: episodeId, suggestedExtension: "mp3")
        var request = URLRequest(url: remoteURL)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/*", forHTTPHeaderField: "Accept")

        let task = session.downloadTask(with: request)
        activeTask = task
        activeEpisodeId = episodeId
        activeProgress = progress
        activeDestination = destination

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.activeContinuation = continuation
                task.resume()
            }
        } onCancel: { [weak self] in
            // Cooperative-cancellation hop: the Task that called ensureDownloaded
            // was cancelled (e.g. by inflightPlayTask?.cancel()). Tear the
            // download down on the main actor — but only if THIS task is still
            // the active one. Otherwise the hop can race a fast episode-switch
            // and end up cancelling the newer download instead.
            Task { @MainActor [weak self] in
                self?.cancelIfActive(task)
            }
        }
    }

    func cancelActive() {
        guard let task = activeTask else { return }
        cancelTask(task)
    }

    /// Identity-scoped cancel: only act if `task` is still the active one.
    /// Used by the stale-cancellation-handler path so a deferred `onCancel`
    /// can't cancel a download for a *different* episode that has since
    /// taken its place.
    private func cancelIfActive(_ task: URLSessionDownloadTask) {
        guard activeTask === task else { return }
        cancelTask(task)
    }

    private func cancelTask(_ task: URLSessionDownloadTask) {
        task.cancel()
        activeTask = nil
        let continuation = activeContinuation
        activeContinuation = nil
        activeEpisodeId = nil
        activeProgress = nil
        activeDestination = nil
        continuation?.resume(throwing: DownloadError.cancelled)
    }

    /// Returns the local file URL for an episode if present and non-empty, else nil.
    func cachedFileURL(episodeId: Int) -> URL? {
        guard let dir = try? Self.cacheDirectoryURL() else { return nil }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        let stem = "\(episodeId)."
        for entry in entries where entry.lastPathComponent.hasPrefix(stem) {
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 0 {
                return entry
            }
            // Zero-byte file from a prior crashed move; treat as a miss.
            try? fm.removeItem(at: entry)
        }
        return nil
    }

    func purge(episodeId: Int) throws {
        guard let dir = try? Self.cacheDirectoryURL() else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let stem = "\(episodeId)."
        for entry in entries where entry.lastPathComponent.hasPrefix(stem) {
            try fm.removeItem(at: entry)
        }
    }

    func purgeAllExcept(episodeId: Int) throws {
        guard let dir = try? Self.cacheDirectoryURL() else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let keepStem = "\(episodeId)."
        for entry in entries where !entry.lastPathComponent.hasPrefix(keepStem) {
            try? fm.removeItem(at: entry)
        }
    }

    func purgeAll() throws {
        guard let dir = try? Self.cacheDirectoryURL() else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Filesystem layout

    /// Application Support/AudioCache/episodes/. Survives restart so cached audio
    /// is available offline; excluded from iCloud backup so multi-MB clips don't
    /// inflate backups.
    static func cacheDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("AudioCache/episodes", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // Mark the parent AudioCache dir as excluded from backup.
            var parent = dir.deletingLastPathComponent()
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? parent.setResourceValues(resourceValues)
        }
        return dir
    }

    private static func destinationURL(for episodeId: Int, suggestedExtension: String) throws -> URL {
        let dir = try cacheDirectoryURL()
        return dir.appendingPathComponent("\(episodeId).\(suggestedExtension)", isDirectory: false)
    }

    /// Map a Content-Type / suggested filename to a file extension. Falls back to
    /// "mp3", which AVPlayer can usually still play even when the header sniff
    /// disagrees with the extension.
    nonisolated private static func fileExtension(for response: URLResponse?) -> String {
        if let mime = response?.mimeType?.lowercased() {
            switch mime {
            case "audio/mpeg", "audio/mp3": return "mp3"
            case "audio/mp4", "audio/x-m4a": return "m4a"
            case "audio/aac": return "aac"
            case "audio/ogg": return "ogg"
            case "audio/wav", "audio/x-wav": return "wav"
            case "audio/flac", "audio/x-flac": return "flac"
            default: break
            }
        }
        if let suggested = response?.suggestedFilename {
            let ext = (suggested as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return "mp3"
    }
}

// MARK: - URLSessionDownloadDelegate

extension AudioDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [weak self] in
            self?.activeProgress?(min(max(fraction, 0), 1))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temp file at `location` is deleted as soon as this delegate
        // returns, so we must move it synchronously on the delegate queue
        // before hopping to the main actor.
        let response = downloadTask.response
        let ext = Self.fileExtension(for: response)

        // The delegate queue IS the main queue (see `session` initializer above
        // — delegateQueue: .main is load-bearing). Fail fast in debug if anyone
        // changes that, since assumeIsolated would otherwise crash with a less
        // diagnosable runtime trap on a non-main queue.
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            guard let episodeId = self.activeEpisodeId else { return }

            // Recompute destination with the actual extension so e.g. an m4a
            // doesn't sit on disk as `.mp3`.
            let finalURL: URL
            do {
                let dir = try Self.cacheDirectoryURL()
                finalURL = dir.appendingPathComponent("\(episodeId).\(ext)", isDirectory: false)
            } catch {
                self.completeWithError(.fileSystem(error))
                return
            }

            // Surface non-2xx responses as errors. AVPlayer would otherwise try
            // to decode an HTML error body as audio.
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200, 206:
                    break
                case 401:
                    self.completeWithError(.unauthorized)
                    return
                default:
                    self.completeWithError(.http(http.statusCode))
                    return
                }
            }

            let fm = FileManager.default
            try? fm.removeItem(at: finalURL) // overwrite if a stale file is present
            do {
                try fm.moveItem(at: location, to: finalURL)
            } catch {
                self.completeWithError(.fileSystem(error))
                return
            }
            self.completeWithSuccess(finalURL)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return } // success path is handled in didFinishDownloadingTo
        // Same delegateQueue: .main coupling as above — see `session` initializer.
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            if let urlError = error as? URLError {
                if urlError.code == .cancelled {
                    // cancelActive() already resumed the continuation.
                    return
                }
                self.completeWithError(.transport(urlError))
            } else {
                self.completeWithError(.fileSystem(error))
            }
        }
    }

    @MainActor
    private func completeWithSuccess(_ url: URL) {
        activeProgress?(1.0)
        let continuation = activeContinuation
        activeContinuation = nil
        activeTask = nil
        activeEpisodeId = nil
        activeProgress = nil
        activeDestination = nil
        continuation?.resume(returning: url)
    }

    @MainActor
    private func completeWithError(_ error: DownloadError) {
        let continuation = activeContinuation
        activeContinuation = nil
        activeTask = nil
        activeEpisodeId = nil
        activeProgress = nil
        activeDestination = nil
        continuation?.resume(throwing: error)
    }
}
