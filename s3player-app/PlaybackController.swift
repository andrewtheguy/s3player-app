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

enum PlaybackPhase: Equatable {
    case idle
    case preparing
    case downloading(Double)
    case ready
    case offline

    var isBusy: Bool {
        switch self {
        case .preparing, .downloading: return true
        default: return false
        }
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    let auth: AuthViewModel
    let player = AudioPlayerViewModel()
    let downloader = AudioDownloader()

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var currentShow: ShowDetail?
    @Published private(set) var sessionState: SessionState = .inactive
    @Published private(set) var loadError: String?
    @Published private(set) var replayConfirmNeeded: Bool = false
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var isOffline: Bool = false
    @Published private(set) var cachedChapters: [Chapter] = []
    /// File extension of the audio file backing the current snapshot
    /// (e.g. "mp3", "m4a", "ogg"). Mirrors `cachedSnapshot.downloadedFileExtension`
    /// so views can react without reaching into the private snapshot.
    @Published private(set) var currentAudioFormat: String?
    @Published var isExpanded: Bool = false
    /// Bumped each time a completion lands durably on the server (either via
    /// the natural-end save or a queued-flush retry). Views that show
    /// "in-progress" or "recently completed" rails observe this so they refresh
    /// immediately instead of waiting for their own polling timer.
    @Published private(set) var completionTick: Int = 0
    /// Bumped on the first successful progress save for a newly selected
    /// episode. Lets the home rails surface the new entry at the top of
    /// "Continue listening" right away, without firing on every routine
    /// 5-second progress tick during long playback.
    @Published private(set) var currentEpisodeTick: Int = 0

    private var cancellables = Set<AnyCancellable>()
    private var progressTask: Task<Void, Never>?
    private var inflightPlayTask: Task<Void, Never>?
    private var lastSavedPositionMs: Int = -1
    private var lastTickedEpisodeId: Int?
    private var resumePositionMs: Int = 0
    private var suppressNextPauseProgressSave = false
    /// Set while a user-initiated mark-completed is in flight. Mirrors the web
    /// frontend's `justMarkedCompletedRef`: gates `saveProgressIfActive` so the
    /// pause we trigger after the manual completion can't race a completed=false
    /// write against our completed=true write.
    private var manualCompletionInFlight = false
    private static let progressSaveInterval: UInt64 = 5_000_000_000

    private let snapshotStore: PlaybackSnapshotStore?
    private let pendingProgressStore: PendingProgressStore?
    /// Mirror of the on-disk snapshot. Read instead of calling
    /// `snapshotStore.load()` on the hot path (every 5 s progress save).
    /// Kept in sync with disk: assigned in init from the initial load and
    /// after every successful `store.save(...)`; cleared on logout.
    private var cachedSnapshot: PlaybackSnapshot?

    init(auth: AuthViewModel) {
        self.auth = auth
        self.snapshotStore = try? PlaybackSnapshotStore()
        self.pendingProgressStore = try? PendingProgressStore()
        sessionState = auth.playerSessionToken != nil ? .active : .inactive

        // Reject lock-screen / Control Center "start playback" commands while
        // the session isn't active. Without this gate a Play tap would call
        // AVPlayer.play() directly and resume audio while sessionState stays
        // .displaced, leaving the in-app UI showing "Take Over Playback".
        player.canStartRemotePlayback = { [weak self] in
            self?.canControlPlayback ?? false
        }
        player.setRemotePlayCommandEnabled(canControlPlayback)

        // Hydrate the Now Playing UI from the on-disk snapshot before any
        // network call. The mini bar renders immediately even offline; the
        // user must still tap play to claim a session and start audio.
        let initialSnapshot = snapshotStore?.load()
        self.cachedSnapshot = initialSnapshot
        if let snapshot = initialSnapshot {
            currentEpisode = snapshot.episode
            currentShow = snapshot.show
            cachedChapters = snapshot.chapters
            resumePositionMs = snapshot.progress.position_ms
            replayConfirmNeeded = snapshot.progress.completed
            currentAudioFormat = snapshot.downloadedFileExtension
        }

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
                    if self.suppressNextPauseProgressSave {
                        self.suppressNextPauseProgressSave = false
                    } else {
                        Task { await self.saveProgressIfActive() }
                    }
                }
            }
            .store(in: &cancellables)

        // Natural end of playback: a single progress save with completed=true,
        // then surface the replay-confirm gate so the next periodic tick (which
        // would write completed=false under the new EXCLUDED.completed upsert
        // semantics) doesn't silently un-complete the episode.
        player.$hasFinishedPlayback
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] finished in
                guard let self, finished else { return }
                Task { await self.saveCompletion() }
            }
            .store(in: &cancellables)

        // Surface "duration unknown / Infinity / 0" assets as a load error so
        // the now-playing sheet can render the unplayable banner.
        player.$playbackUnsupported
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] unsupported in
                guard let self, unsupported else { return }
                self.loadError = "This episode reports no duration and can't be played."
            }
            .store(in: &cancellables)

        // Mirror canControlPlayback onto the lock-screen / Control Center
        // play & toggle commands. Disabled buttons render grayed out and
        // can't fire, complementing the in-handler gate.
        Publishers.CombineLatest3(
            $sessionState,
            $replayConfirmNeeded,
            player.$playbackUnsupported
        )
        .map { state, replayNeeded, unsupported in
            state == .active && !replayNeeded && !unsupported
        }
        .removeDuplicates()
        .sink { [weak self] enabled in
            self?.player.setRemotePlayCommandEnabled(enabled)
        }
        .store(in: &cancellables)
    }

    // MARK: - Public API

    func play(episode: Episode, show: ShowDetail) {
        // Cancel any prior in-flight download/prepare so a rapid-tap of a new
        // episode supersedes the old one cleanly.
        inflightPlayTask?.cancel()
        inflightPlayTask = Task { [weak self] in
            await self?.beginPlay(episode: episode, show: show)
        }
    }

    func cancelDownload() {
        inflightPlayTask?.cancel()
        inflightPlayTask = nil
        downloader.cancelActive()
        if phase.isBusy {
            phase = .idle
        }
    }

    func updateCachedChapters(_ chapters: [Chapter]) {
        cachedChapters = chapters
        persistSnapshot()
    }

    /// Kick off the download-and-prepare flow for the episode hydrated from the
    /// on-disk snapshot. Used by the mini bar / sheet when the app launches
    /// with a known last episode but no audio loaded yet.
    func resumeFromSnapshot() {
        guard let episode = currentEpisode, let show = currentShow else { return }
        play(episode: episode, show: show)
    }

    /// True when the snapshot has hydrated the UI but the player hasn't been
    /// prepared yet (typical fresh-launch state).
    var needsResumeFromSnapshot: Bool {
        currentEpisode != nil && !player.hasLoadedAudio && !phase.isBusy
    }

    /// Saved playhead (seconds) for the current episode, taken from the on-disk
    /// snapshot. Surfaced so the mini bar / now-playing sheet can render the
    /// resume position before the audio asset loads and the player starts
    /// reporting its own elapsed/duration. nil when there's no matching snapshot.
    var snapshotResumeSeconds: Double? {
        guard let snapshot = cachedSnapshot,
              snapshot.episode.id == currentEpisode?.id else { return nil }
        return Double(snapshot.progress.position_ms) / 1000
    }

    /// Saved total duration (seconds) for the current episode from the snapshot,
    /// or nil when the snapshot hasn't recorded a usable duration yet. Companion
    /// to [[snapshotResumeSeconds]] for pre-load progress rendering.
    var snapshotDurationSeconds: Double? {
        guard let snapshot = cachedSnapshot,
              snapshot.episode.id == currentEpisode?.id,
              let durationMs = snapshot.progress.duration_ms,
              durationMs > 0 else { return nil }
        return Double(durationMs) / 1000
    }

    func togglePlayback() {
        guard canControlPlayback else { return }
        player.togglePlayback()
    }

    func skip(by seconds: Double) {
        guard canControlPlayback else { return }
        player.skip(by: seconds)
    }

    func seek(toProgress progress: Double) {
        guard canControlPlayback else { return }
        player.seek(to: progress)
        Task { await saveProgressIfActive() }
    }

    func seek(toMilliseconds ms: Int) {
        guard canControlPlayback else { return }
        guard player.hasDuration, player.duration > 0 else { return }
        let progress = Double(ms) / 1000.0 / player.duration
        player.seek(to: min(max(progress, 0), 1))
        Task { await saveProgressIfActive() }
    }

    private var canControlPlayback: Bool {
        sessionState == .active && !replayConfirmNeeded && !player.playbackUnsupported
    }

    func confirmReplay() {
        guard replayConfirmNeeded else { return }
        replayConfirmNeeded = false
        resumePositionMs = 0
        lastSavedPositionMs = -1
        player.setResumePosition(toSeconds: 0)
        if sessionState == .active, !player.isPlaying {
            player.togglePlayback()
        }
    }

    func markCompleted() {
        guard sessionState == .active,
              currentEpisode != nil,
              !replayConfirmNeeded,
              !player.playbackUnsupported,
              !manualCompletionInFlight else { return }
        manualCompletionInFlight = true
        if player.isPlaying {
            player.togglePlayback()
        }
        Task { [weak self] in
            await self?.performManualCompletion()
        }
    }

    private func performManualCompletion() async {
        defer { manualCompletionInFlight = false }
        let positionMs = max(0, Int(player.elapsedTime * 1000))
        let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
        let succeeded = await saveProgress(
            positionMs: positionMs,
            durationMs: durationMs,
            completed: true
        )
        if succeeded || isOffline {
            replayConfirmNeeded = true
        } else if sessionState == .active {
            loadError = "Couldn't mark this episode complete. Try again."
        }
    }

    /// Mark an arbitrary episode complete from outside the now-playing UI.
    /// If the episode matches the active session, routes through the same
    /// in-session path as [[markCompleted]] so the player pauses and the
    /// replay-confirm flow engages. Otherwise issues a one-shot progress
    /// write and bumps [[completionTick]] so the rails refresh.
    @discardableResult
    func markEpisodeCompleted(
        episodeId: Int,
        positionMs: Int,
        durationMs: Int?
    ) async -> Bool {
        if currentEpisode?.id == episodeId,
           sessionState == .active,
           !replayConfirmNeeded,
           !player.playbackUnsupported,
           !manualCompletionInFlight {
            manualCompletionInFlight = true
            if player.isPlaying { player.togglePlayback() }
            await performManualCompletion()
            return replayConfirmNeeded
        }

        guard let client = APIClient(auth: auth),
              let token = auth.playerSessionToken else { return false }
        do {
            try await client.saveProgress(
                episodeId: episodeId,
                playerToken: token,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: true
            )
            completionTick &+= 1
            return true
        } catch APIError.sessionDisplaced {
            handleDisplacement()
            return false
        } catch APIError.unauthorized {
            auth.logout()
            return false
        } catch {
            return false
        }
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

    func requestClaimSession() {
        Task { await self.claimSessionOnly() }
    }

    // MARK: - Episode swap

    private func beginPlay(episode: Episode, show: ShowDetail) async {
        if let prior = currentEpisode, prior.id != episode.id {
            // Snapshot prior position before clearing the old player. The
            // controller saves this progress explicitly, so suppress the pause
            // sink that player.stop() would otherwise schedule for the swap.
            let positionMs = max(0, Int(player.elapsedTime * 1000))
            let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
            stopPlayerForEpisodeSwap()
            await saveProgress(positionMs: positionMs, durationMs: durationMs, completed: false)
            if Task.isCancelled { return }
        }

        let priorEpisodeId = currentEpisode?.id
        currentEpisode = episode
        currentShow = show
        if priorEpisodeId != episode.id {
            cachedChapters = episode.chapters ?? []
            currentAudioFormat = nil
        }
        loadError = nil
        replayConfirmNeeded = false
        resumePositionMs = 0
        lastSavedPositionMs = -1
        phase = .preparing
        if sessionState != .displaced {
            sessionState = auth.playerSessionToken != nil ? .active : .inactive
        }
        isExpanded = true

        if Task.isCancelled { return }

        await fetchResumeAndPrepare(episode: episode, show: show)
    }

    private func fetchResumeAndPrepare(episode: Episode, show: ShowDetail) async {
        guard let client = APIClient(auth: auth) else {
            loadError = "Not signed in."
            phase = .idle
            return
        }

        // Step 1: fetch saved progress. On transport failure, fall back to the
        // snapshot's progress for this episode (so offline resume still works).
        var progressFetched = false
        do {
            let progress = try await client.getProgress(episodeId: episode.id)
            replayConfirmNeeded = progress.completed
            resumePositionMs = progress.position_ms
            progressFetched = true
            isOffline = false
        } catch APIError.unauthorized {
            auth.logout()
            phase = .idle
            return
        } catch APIError.transport {
            isOffline = true
            // Fall through to snapshot fallback below.
        } catch {
            replayConfirmNeeded = false
            resumePositionMs = 0
        }

        if Task.isCancelled { return }

        if !progressFetched,
           let snapshot = cachedSnapshot,
           snapshot.episode.id == episode.id {
            replayConfirmNeeded = snapshot.progress.completed
            resumePositionMs = snapshot.progress.position_ms
        }

        // Persist the snapshot now that we have the latest known progress, even
        // if the audio file isn't on disk yet — the mini bar should show the
        // correct resume time as soon as possible. Pull duration_ms from the
        // in-memory cache so we don't hit disk twice in a row.
        persistSnapshot(progressOverride: ProgressResponse(
            position_ms: resumePositionMs,
            duration_ms: cachedSnapshot?.episode.id == episode.id
                ? cachedSnapshot?.progress.duration_ms
                : nil,
            completed: replayConfirmNeeded,
            last_played_at: nil
        ))

        // Step 2: ensure the audio is on disk.
        guard let remoteURL = client.audioStreamURL(episodeId: episode.id) else {
            loadError = "Could not build audio URL."
            phase = .idle
            return
        }

        let localURL: URL
        do {
            phase = .downloading(0)
            localURL = try await downloader.ensureDownloaded(
                episodeId: episode.id,
                remoteURL: remoteURL,
                bearerToken: client.bearerToken
            ) { [weak self] fraction in
                guard let self else { return }
                self.phase = .downloading(fraction)
            }
            isOffline = false
        } catch AudioDownloader.DownloadError.cancelled {
            return
        } catch AudioDownloader.DownloadError.unauthorized {
            auth.logout()
            phase = .idle
            return
        } catch {
            // Transport / HTTP / FS failure. If we already have a cached file
            // for this episode (downloaded on a prior run), use it.
            if let cached = downloader.cachedFileURL(episodeId: episode.id) {
                localURL = cached
                if case AudioDownloader.DownloadError.transport = error {
                    isOffline = true
                }
            } else {
                if case AudioDownloader.DownloadError.transport = error {
                    isOffline = true
                }
                phase = .offline
                loadError = "Couldn't download episode and no cached copy is available."
                return
            }
        }

        if Task.isCancelled { return }

        phase = .ready

        // Step 3: hand the file to the player.
        let resumeSeconds = Double(resumePositionMs) / 1000
        player.prepare(
            url: localURL,
            httpHeaders: [:],
            resumeAtSeconds: resumeSeconds,
            title: nowPlayingTitle(for: episode),
            artist: show.name
        )
        lastSavedPositionMs = resumePositionMs

        // Persist the file extension so the snapshot reflects what's on disk.
        let ext = (localURL.lastPathComponent as NSString).pathExtension
        persistSnapshot(downloadedFileExtensionOverride: ext)

        if sessionState == .active, !player.isPlaying, !replayConfirmNeeded {
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

    private func claimSessionOnly() async {
        guard let client = APIClient(auth: auth) else { return }
        let fallbackState: SessionState = sessionState == .displaced ? .displaced : .inactive
        sessionState = .activating
        loadError = nil
        do {
            let claim = try await client.claimSession()
            auth.setPlayerSessionToken(claim.session_token)
            sessionState = .active
            isOffline = false
            if currentEpisode != nil {
                await syncResumePositionFromServer(client: client)
            }
        } catch APIError.unauthorized {
            auth.logout()
        } catch APIError.transport(let urlError) {
            sessionState = fallbackState
            loadError = urlError.localizedDescription
        } catch {
            sessionState = fallbackState
            loadError = errorMessage(error)
        }
    }

    private func claimSessionAndPlay(fallbackState: SessionState) async {
        guard let client = APIClient(auth: auth) else { return }
        sessionState = .activating
        loadError = nil
        do {
            let claim = try await client.claimSession()
            auth.setPlayerSessionToken(claim.session_token)
            sessionState = .active
            isOffline = false
            // Fresh-launch path: snapshot hydrated currentEpisode/currentShow but
            // the player asset is unloaded. togglePlayback() would no-op — kick
            // off the download/prepare flow instead. play() will re-fetch
            // progress and auto-toggle on completion.
            if !player.hasLoadedAudio,
               let episode = currentEpisode,
               let show = currentShow {
                play(episode: episode, show: show)
                return
            }
            // Already-loaded path: sync to the latest server-side position so a
            // take-over (or a delayed Start Playback) resumes from wherever the
            // prior holder left off, not the snapshot we fetched at beginPlay
            // time. Then start playback. Skip auto-play when a replay gate or
            // unplayable asset is in the way — either is "needs user action".
            await syncResumePositionFromServer(client: client)
            if !player.isPlaying, !replayConfirmNeeded, !player.playbackUnsupported {
                player.togglePlayback()
            }
        } catch APIError.unauthorized {
            auth.logout()
        } catch APIError.transport(let urlError) {
            // No network: if we have the audio on disk and a snapshot, allow
            // local playback without claiming the server session. The user gets
            // immediate listening; on reconnect, the next saveProgress reveals
            // any server-side displacement and the existing handler runs.
            if let episode = currentEpisode,
               let show = currentShow,
               downloader.cachedFileURL(episodeId: episode.id) != nil {
                sessionState = .active
                isOffline = true
                if !player.hasLoadedAudio {
                    // Same fresh-launch case as the online path: prepare the
                    // cached audio before trying to play.
                    play(episode: episode, show: show)
                } else if !player.isPlaying, !replayConfirmNeeded, !player.playbackUnsupported {
                    player.togglePlayback()
                }
            } else {
                sessionState = fallbackState
                loadError = urlError.localizedDescription
            }
        } catch {
            sessionState = fallbackState
            loadError = errorMessage(error)
        }
    }

    private func syncResumePositionFromServer(client: APIClient) async {
        guard let episode = currentEpisode else { return }
        do {
            let progress = try await client.getProgress(episodeId: episode.id)
            replayConfirmNeeded = progress.completed
            let positionMs = progress.position_ms
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
        // Skip on natural end: the isPlaying=false sink and the
        // hasFinishedPlayback=true sink both fire from the AVPlayer end
        // notification, scheduling this (completed=false) and saveCompletion
        // (completed=true) as concurrent writes to the same row. Without this
        // guard the two POSTs race and the server can keep the false one.
        guard sessionState == .active,
              !replayConfirmNeeded,
              !player.hasFinishedPlayback,
              !manualCompletionInFlight,
              !player.playbackUnsupported else { return }
        let positionMs = max(0, Int(player.elapsedTime * 1000))
        let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
        await saveProgress(positionMs: positionMs, durationMs: durationMs, completed: false)
    }

    @discardableResult
    private func saveProgress(positionMs: Int, durationMs: Int?, completed: Bool) async -> Bool {
        guard sessionState == .active,
              let episode = currentEpisode,
              !player.playbackUnsupported else { return false }
        // Always allow the completion write through, even if the position has
        // not advanced since the last save (the natural-end tick can land on
        // the same ms as the prior periodic tick).
        if positionMs == lastSavedPositionMs && !completed { return true }

        // Update the on-disk snapshot first so the offline UI reflects the
        // playhead even when the server write is queued.
        persistSnapshot(progressOverride: ProgressResponse(
            position_ms: positionMs,
            duration_ms: durationMs,
            completed: completed,
            last_played_at: nil
        ))

        // Without a player session token we can't write to the server. Queue
        // locally and bail; the queue flushes on the next successful claim/save.
        guard let token = auth.playerSessionToken,
              let client = APIClient(auth: auth) else {
            enqueuePendingProgress(
                episodeId: episode.id,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: completed
            )
            return false
        }

        do {
            try await client.saveProgress(
                episodeId: episode.id,
                playerToken: token,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: completed
            )
            lastSavedPositionMs = positionMs
            isOffline = false
            if completed { completionTick &+= 1 }
            if lastTickedEpisodeId != episode.id {
                lastTickedEpisodeId = episode.id
                currentEpisodeTick &+= 1
            }
            await flushPendingProgress(client: client, playerToken: token)
            return true
        } catch APIError.sessionDisplaced {
            handleDisplacement()
            return false
        } catch APIError.unauthorized {
            auth.logout()
            return false
        } catch APIError.transport {
            isOffline = true
            enqueuePendingProgress(
                episodeId: episode.id,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: completed
            )
            return false
        } catch {
            // Transient non-transport: keep playing; the next tick or pause retries.
            return false
        }
    }

    private func enqueuePendingProgress(
        episodeId: Int,
        positionMs: Int,
        durationMs: Int?,
        completed: Bool
    ) {
        pendingProgressStore?.append(PendingProgressEntry(
            episodeId: episodeId,
            positionMs: positionMs,
            durationMs: durationMs,
            completed: completed,
            recordedAt: Date()
        ))
    }

    private func flushPendingProgress(client: APIClient, playerToken: String) async {
        guard let store = pendingProgressStore else { return }
        let pending = store.snapshotForFlush()
        for entry in pending {
            // Skip the entry that matches the just-sent write — it would be a
            // no-op duplicate and the call site already cleared lastSavedPositionMs.
            if entry.episodeId == currentEpisode?.id, entry.positionMs == lastSavedPositionMs {
                store.remove(episodeId: entry.episodeId, recordedAtOrBefore: entry.recordedAt)
                continue
            }
            do {
                try await client.saveProgress(
                    episodeId: entry.episodeId,
                    playerToken: playerToken,
                    positionMs: entry.positionMs,
                    durationMs: entry.durationMs,
                    completed: entry.completed
                )
                store.remove(episodeId: entry.episodeId, recordedAtOrBefore: entry.recordedAt)
                if entry.completed { completionTick &+= 1 }
            } catch {
                // Stop flushing on the first failure; we'll retry on the next save.
                return
            }
        }
    }

    private func saveCompletion() async {
        guard sessionState == .active,
              currentEpisode != nil,
              !player.playbackUnsupported else { return }
        // No `playerSessionToken != nil` guard here: the offline-bypass branch
        // in `claimSessionAndPlay` runs the user as `.active` without a token,
        // and saveProgress already handles that case by writing the snapshot
        // and enqueueing the entry for flush-on-reconnect. Skipping completion
        // there would silently drop a natural-end save.
        let positionMs = max(0, Int(player.elapsedTime * 1000))
        let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
        let succeeded = await saveProgress(
            positionMs: positionMs,
            durationMs: durationMs,
            completed: true
        )
        // Flip the replay-confirm gate when the completion is durably recorded:
        // - succeeded: server confirmed.
        // - isOffline: snapshot was updated to completed=true and the entry is
        //   queued for the next reconnect, so the user has logically finished
        //   the episode — the gate should appear and prevent the next periodic
        //   tick from un-completing it.
        // Real online failures (sessionDisplaced, non-transport errors) leave
        // both succeeded=false and isOffline=false — surface the retry banner.
        if succeeded || isOffline {
            replayConfirmNeeded = true
        } else if sessionState == .active {
            loadError = "Couldn't mark this episode complete. Tap play to retry."
        }
    }

    // MARK: - Reset

    private func resetForLogout() {
        stopProgressTimer()
        inflightPlayTask?.cancel()
        inflightPlayTask = nil
        downloader.cancelActive()
        try? downloader.purgeAll()
        try? snapshotStore?.clear()
        cachedSnapshot = nil
        currentAudioFormat = nil
        pendingProgressStore?.clear()
        player.stop()
        currentEpisode = nil
        currentShow = nil
        cachedChapters = []
        sessionState = .inactive
        loadError = nil
        replayConfirmNeeded = false
        isExpanded = false
        resumePositionMs = 0
        lastSavedPositionMs = -1
        lastTickedEpisodeId = nil
        phase = .idle
        isOffline = false
    }

    // MARK: - Snapshot

    /// Persist the current Now Playing state to disk so the next launch (online
    /// or offline) can hydrate the mini bar before any network call. Reads from
    /// `cachedSnapshot` instead of `store.load()` to avoid a disk read on every
    /// 5-second progress save.
    private func persistSnapshot(
        progressOverride: ProgressResponse? = nil,
        downloadedFileExtensionOverride: String? = nil
    ) {
        guard let store = snapshotStore,
              let episode = currentEpisode,
              let show = currentShow else { return }
        let existing = cachedSnapshot?.episode.id == episode.id ? cachedSnapshot : nil
        let progress = progressOverride
            ?? existing?.progress
            ?? ProgressResponse(
                position_ms: resumePositionMs,
                duration_ms: nil,
                completed: replayConfirmNeeded,
                last_played_at: nil
            )
        let extName = downloadedFileExtensionOverride
            ?? existing?.downloadedFileExtension
        let snapshot = PlaybackSnapshot(
            episode: episode,
            show: show,
            chapters: cachedChapters,
            progress: progress,
            downloadedFileExtension: extName,
            updatedAt: Date()
        )
        do {
            try store.save(snapshot)
            cachedSnapshot = snapshot
            currentAudioFormat = extName
        } catch {
            // Failed disk write: leave cachedSnapshot untouched so the next
            // attempt sees the same baseline (don't pretend the write landed).
        }
    }

    // MARK: - Helpers

    private func stopPlayerForEpisodeSwap() {
        if player.isPlaying {
            suppressNextPauseProgressSave = true
        }
        player.stop()
    }

    private func nowPlayingTitle(for episode: Episode) -> String {
        let date = DateFormatter.sharedISODate.string(from: episode.aired_on)
        let slot = formatTimeSlot(episode.time_slot)
        return slot.isEmpty ? date : "\(date) · \(slot)"
    }
}
