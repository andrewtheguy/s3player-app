//
//  PlayerView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

private enum SessionState {
    case inactive
    case activating
    case active
    case displaced
}

struct PlayerView: View {
    let episode: Episode
    let show: ShowDetail
    @ObservedObject var auth: AuthViewModel
    @StateObject private var player = AudioPlayerViewModel()
    @State private var scrubberProgress: Double = 0
    @State private var isScrubbing = false
    @State private var loadError: String?
    @State private var didStartLoad = false
    @State private var sessionState: SessionState = .inactive
    @State private var resumePositionMs: Int = 0
    @State private var hasFetchedProgress = false
    @State private var progressTask: Task<Void, Never>?
    @State private var lastSavedPositionMs: Int = -1

    private let progressSaveInterval: UInt64 = 5_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                metadata
                playbackControls
                if sessionState == .active {
                    progressView
                }
                statusView
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
        }
        .navigationTitle(show.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(groupedBackground)
        .task {
            guard !didStartLoad else { return }
            didStartLoad = true
            // Launch-time validation in AuthViewModel has already resolved the rehydrated token; trust the resulting state here.
            if auth.playerSessionToken != nil {
                sessionState = .active
            }
            await fetchResumeAndPrepare()
        }
        .onChange(of: player.progress) { _, newProgress in
            guard !isScrubbing else { return }
            scrubberProgress = newProgress
        }
        .onChange(of: player.isPlaying) { _, isPlaying in
            if isPlaying {
                startProgressTimer()
            } else {
                stopProgressTimer()
                Task { await saveProgressIfActive() }
            }
        }
        .onChange(of: player.hasFinishedPlayback) { _, finished in
            if finished {
                Task { await markEpisodeCompleted() }
            }
        }
        .onChange(of: auth.playerSessionToken) { _, newToken in
            // Heartbeat or another path cleared the token externally — reflect the displacement here.
            if newToken == nil, sessionState == .active || sessionState == .activating {
                sessionState = .displaced
                if player.isPlaying { player.togglePlayback() }
            }
        }
        .onDisappear {
            stopProgressTimer()
            // Snapshot position before player.stop() resets elapsedTime to 0; the detached Task captures these values.
            let positionMs = max(0, Int(player.elapsedTime * 1000))
            let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
            Task { await saveProgress(positionMs: positionMs, durationMs: durationMs) }
            player.stop()
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(show.name)
                .font(.title2.bold())
            HStack(spacing: 8) {
                Text(formattedDate(episode.aired_on))
                let slot = formatTimeSlot(episode.time_slot)
                if !slot.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(slot)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var playbackControls: some View {
        switch sessionState {
        case .displaced:
            Button(action: takeOver) {
                Label("Take Over Playback", systemImage: "arrow.uturn.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
        case .inactive:
            Button(action: { Task { await activateAndPlay() } }) {
                Label("Start Playback", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .activating:
            Button {
            } label: {
                Label("Connecting…", systemImage: "hourglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)
        case .active:
            HStack(spacing: 16) {
                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!player.hasDuration)

                Button(action: handlePlayTap) {
                    Label(
                        player.isPlaying ? "Pause" : "Play",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!player.hasLoadedAudio || player.isLoading)

                Button {
                    player.skip(by: 30)
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!player.hasDuration)
            }
        }
    }

    private var progressView: some View {
        VStack(spacing: 10) {
            Slider(
                value: $scrubberProgress,
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        player.seek(to: scrubberProgress)
                        Task { await saveProgressIfActive() }
                    }
                }
            )
            .disabled(!player.hasDuration)

            HStack {
                Text(player.formattedTime(player.elapsedTime))
                Spacer()
                Text(player.hasDuration ? player.formattedTime(player.duration) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            } else if sessionState == .displaced {
                Label("Another device is playing. Take over to continue.", systemImage: "arrow.uturn.right")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            } else if sessionState == .inactive {
                Label("Tap Start Playback to claim playback on this device.", systemImage: "play.circle")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Label(player.statusMessage, systemImage: player.isLoading ? "hourglass" : "waveform")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    private func fetchResumeAndPrepare() async {
        guard let client = APIClient(auth: auth) else {
            loadError = "Not signed in."
            return
        }

        if !hasFetchedProgress {
            do {
                let progress = try await client.getProgress(episodeId: episode.id)
                resumePositionMs = progress.completed ? 0 : progress.position_ms
                hasFetchedProgress = true
            } catch APIError.unauthorized {
                auth.logout()
                return
            } catch {
                resumePositionMs = 0
                hasFetchedProgress = true
            }
        }

        do {
            let response = try await client.getAudioURL(episodeId: episode.id)
            guard let url = URL(string: response.url) else {
                loadError = "Server returned an invalid audio URL."
                return
            }
            let resumeSeconds = Double(resumePositionMs) / 1000
            player.prepare(
                url: url,
                resumeAtSeconds: resumeSeconds,
                title: nowPlayingTitle,
                artist: show.name
            )
            lastSavedPositionMs = resumePositionMs
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            loadError = errorMessage(error)
        }
    }

    private func handlePlayTap() {
        guard sessionState == .active else { return }
        player.togglePlayback()
    }

    private func handleDisplacement() {
        auth.setPlayerSessionToken(nil)
        sessionState = .displaced
        if player.isPlaying { player.togglePlayback() }
    }

    private func activateAndPlay() async {
        guard let client = APIClient(auth: auth) else { return }
        sessionState = .activating
        loadError = nil

        do {
            let claim = try await client.claimSession()
            auth.setPlayerSessionToken(claim.session_token)
            sessionState = .active
            player.togglePlayback()
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            sessionState = .inactive
            loadError = errorMessage(error)
        }
    }

    private func takeOver() {
        Task {
            guard let client = APIClient(auth: auth) else { return }
            sessionState = .activating
            loadError = nil
            do {
                let claim = try await client.claimSession()
                auth.setPlayerSessionToken(claim.session_token)
                sessionState = .active
                player.togglePlayback()
            } catch APIError.unauthorized {
                auth.logout()
            } catch {
                sessionState = .displaced
                loadError = errorMessage(error)
            }
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTask = Task { [progressSaveInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: progressSaveInterval)
                if Task.isCancelled { return }
                await saveProgressIfActive()
            }
        }
    }

    private func stopProgressTimer() {
        progressTask?.cancel()
        progressTask = nil
    }

    private func markEpisodeCompleted() async {
        guard sessionState == .active,
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

    private func saveProgressIfActive() async {
        guard sessionState == .active else { return }
        let positionMs = max(0, Int(player.elapsedTime * 1000))
        let durationMs = player.hasDuration ? Int(player.duration * 1000) : nil
        await saveProgress(positionMs: positionMs, durationMs: durationMs)
    }

    private func saveProgress(positionMs: Int, durationMs: Int?) async {
        guard sessionState == .active,
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
            // Transient network or server errors: keep playing, retry on next tick.
        }
    }

    private func formattedDate(_ date: Date) -> String {
        Self.airedOnFormatter.string(from: date)
    }

    private var nowPlayingTitle: String {
        let date = Self.airedOnFormatter.string(from: episode.aired_on)
        let slot = formatTimeSlot(episode.time_slot)
        return slot.isEmpty ? date : "\(date) · \(slot)"
    }

    private static let airedOnFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var groupedBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }
}

private func errorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        return apiError.errorDescription ?? "Request failed."
    }
    return error.localizedDescription
}
