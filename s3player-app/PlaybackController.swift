//
//  PlaybackController.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import Combine
import Foundation

enum SessionState {
    case inactive
    case activating
    case active
    case displaced
}

@MainActor
final class PlaybackController: ObservableObject {
    let auth: AuthViewModel
    let player = AudioPlayerViewModel()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var currentShow: ShowDetail?
    @Published private(set) var sessionState: SessionState = .inactive
    @Published private(set) var loadError: String?
    @Published var isExpanded: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var progressTask: Task<Void, Never>?
    private var lastSavedPositionMs: Int = -1
    private var resumePositionMs: Int = 0
    private static let progressSaveInterval: UInt64 = 5_000_000_000

    init(auth: AuthViewModel) {
        self.auth = auth
        sessionState = auth.playerSessionToken != nil ? .active : .inactive

        // Heartbeat / external clear: any token transition while we're active or
        // mid-activation flips us to .displaced and pauses. Idempotent if already there.
        auth.$playerSessionToken
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newToken in
                guard let self else { return }
                if newToken == nil,
                   self.sessionState == .active || self.sessionState == .activating {
                    self.handleDisplacement()
                }
            }
            .store(in: &cancellables)

        // Sign-out: bearer token cleared (logout, 401). Reset playback so the
        // mini bar disappears and audio stops.
        auth.$token
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newToken in
                guard let self, newToken == nil else { return }
                self.resetForLogout()
            }
            .store(in: &cancellables)

        // Pause/play edges drive the periodic progress timer + flush-on-pause.
        player.$isPlaying
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying {
                    self.startProgressTimer()
                } else {
                    self.stopProgressTimer()
                    Task { await self.saveProgressIfActive() }
                }
            }
            .store(in: &cancellables)

        // Natural end of playback: complete + final progress save.
        player.$hasFinishedPlayback
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] finished in
                guard let self, finished else { return }
                Task { await self.markEpisodeCompleted() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func play(episode: Episode, show: ShowDetail) {
        Task { await self.beginPlay(episode: episode, show: show) }
    }

    func togglePlayback() {
        guard sessionState == .active else { return }
        player.togglePlayback()
    }

    func skip(by seconds: Double) {
        guard sessionState == .active else { return }
        player.skip(by: seconds)
    }

    func seek(toProgress progress: Double) {
        guard sessionState == .active else { return }
        player.seek(to: progress)
        Task { await saveProgressIfActive() }
    }

    func seek(toMilliseconds ms: Int) {
        guard sessionState == .active else { return }
        guard player.hasDuration, player.duration > 0 else { return }
        let progress = Double(ms) / 1000.0 / player.duration
        player.seek(to: min(max(progress, 0), 1))
        Task { await saveProgressIfActive() }
    }

    func expand() {
        isExpanded = true
    }

    func requestActivate() {
        Task { await self.activateAndPlay() }
    }

    func requestTakeOver() {
        Task { await self.takeOver() }
    }

    // MARK: - Episode swap

    private func beginPlay(episode: Episode, show: ShowDetail) async {
        if let prior = currentEpisode, prior.id != episode.id {
            // Snapshot prior position before player.stop() resets it inside prepare.
            let positionMs = max(0, Int(player.elapsedTime * 1000))
            let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
            await saveProgress(positionMs: positionMs, durationMs: durationMs)
        }

        currentEpisode = episode
        currentShow = show
        loadError = nil
        resumePositionMs = 0
        lastSavedPositionMs = -1
        if sessionState != .displaced {
            sessionState = auth.playerSessionToken != nil ? .active : .inactive
        }
        isExpanded = true

        await fetchResumeAndPrepare(episode: episode, show: show)
    }

    private func fetchResumeAndPrepare(episode: Episode, show: ShowDetail) async {
        guard let client = APIClient(auth: auth) else {
            loadError = "Not signed in."
            return
        }

        do {
            let progress = try await client.getProgress(episodeId: episode.id)
            resumePositionMs = progress.completed ? 0 : progress.position_ms
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            resumePositionMs = 0
        }

        guard let url = client.audioStreamURL(episodeId: episode.id) else {
            loadError = "Could not build audio URL."
            return
        }
        let resumeSeconds = Double(resumePositionMs) / 1000
        player.prepare(
            url: url,
            httpHeaders: client.authorizationHeaders,
            resumeAtSeconds: resumeSeconds,
            title: nowPlayingTitle(for: episode),
            artist: show.name
        )
        lastSavedPositionMs = resumePositionMs
        if sessionState == .active, !player.isPlaying {
            player.togglePlayback()
        }
    }

    // MARK: - Session transitions

    private func activateAndPlay() async {
        await claimSessionAndPlay(fallbackState: .inactive)
    }

    private func takeOver() async {
        await claimSessionAndPlay(fallbackState: .displaced)
    }

    private func claimSessionAndPlay(fallbackState: SessionState) async {
        guard let client = APIClient(auth: auth) else { return }
        sessionState = .activating
        loadError = nil
        do {
            let claim = try await client.claimSession()
            auth.setPlayerSessionToken(claim.session_token)
            sessionState = .active
            // Sync to the latest server-side position so a take-over (or a delayed
            // Start Playback) resumes from wherever the prior holder left off,
            // not the snapshot we fetched at beginPlay time.
            await syncResumePositionFromServer(client: client)
            // A successful claim should leave the prepared player running, even if
            // overlapping claim completions arrive after playback has already started.
            if !player.isPlaying {
                player.togglePlayback()
            }
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            sessionState = fallbackState
            loadError = errorMessage(error)
        }
    }

    private func syncResumePositionFromServer(client: APIClient) async {
        guard let episode = currentEpisode else { return }
        do {
            let progress = try await client.getProgress(episodeId: episode.id)
            let positionMs = progress.completed ? 0 : progress.position_ms
            player.setResumePosition(toSeconds: Double(positionMs) / 1000)
            resumePositionMs = positionMs
            lastSavedPositionMs = positionMs
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            // Transient: keep the existing prepared resume position.
        }
    }

    private func handleDisplacement() {
        if auth.playerSessionToken != nil {
            auth.setPlayerSessionToken(nil)
        }
        sessionState = .displaced
        if player.isPlaying { player.togglePlayback() }
    }

    // MARK: - Progress / completion

    private func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.progressSaveInterval)
                if Task.isCancelled { return }
                await self?.saveProgressIfActive()
            }
        }
    }

    private func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func saveProgressIfActive() async {
        guard sessionState == .active else { return }
        let positionMs = max(0, Int(player.elapsedTime * 1000))
        let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
        await saveProgress(positionMs: positionMs, durationMs: durationMs)
    }

    private func saveProgress(positionMs: Int, durationMs: Int?) async {
        guard sessionState == .active,
              let episode = currentEpisode,
              let token = auth.playerSessionToken,
              let client = APIClient(auth: auth) else { return }
        if positionMs == lastSavedPositionMs { return }
        do {
            try await client.saveProgress(
                episodeId: episode.id,
                playerToken: token,
                positionMs: positionMs,
                durationMs: durationMs
            )
            lastSavedPositionMs = positionMs
        } catch APIError.sessionDisplaced {
            handleDisplacement()
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            // Transient: keep playing; the next tick or pause retries.
        }
    }

    private func markEpisodeCompleted() async {
        guard sessionState == .active,
              let episode = currentEpisode,
              let token = auth.playerSessionToken,
              let client = APIClient(auth: auth) else { return }
        await saveProgressIfActive()
        do {
            try await client.markComplete(episodeId: episode.id, playerToken: token)
        } catch APIError.sessionDisplaced {
            handleDisplacement()
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            loadError = errorMessage(error)
        }
    }

    // MARK: - Reset

    private func resetForLogout() {
        stopProgressTimer()
        player.stop()
        currentEpisode = nil
        currentShow = nil
        sessionState = .inactive
        loadError = nil
        isExpanded = false
        resumePositionMs = 0
        lastSavedPositionMs = -1
    }

    // MARK: - Helpers

    private func nowPlayingTitle(for episode: Episode) -> String {
        let date = DateFormatter.sharedISODate.string(from: episode.aired_on)
        let slot = formatTimeSlot(episode.time_slot)
        return slot.isEmpty ? date : "\(date) · \(slot)"
    }
}
