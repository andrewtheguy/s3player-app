//
//  PlayerView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct PlayerView: View {
    let episode: Episode
    let show: ShowDetail
    @ObservedObject var auth: AuthViewModel
    @StateObject private var player = AudioPlayerViewModel()
    @State private var scrubberProgress: Double = 0
    @State private var isScrubbing = false
    @State private var loadError: String?
    @State private var didStartLoad = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                metadata
                playbackControls
                progressView
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
            await loadAndPlay()
        }
        .onChange(of: player.progress) { _, newProgress in
            guard !isScrubbing else { return }
            scrubberProgress = newProgress
        }
        .onDisappear {
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

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlayback) {
                Label(
                    player.isPlaying ? "Pause" : "Play",
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!player.hasLoadedAudio || player.isLoading)
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
            } else {
                Label(player.statusMessage, systemImage: player.isLoading ? "hourglass" : "waveform")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    private func loadAndPlay() async {
        guard let client = APIClient(auth: auth) else {
            loadError = "Not signed in."
            return
        }
        do {
            let response = try await client.getAudioURL(episodeId: episode.id)
            guard let url = URL(string: response.url) else {
                loadError = "Server returned an invalid audio URL."
                return
            }
            player.prepare(url: url)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            loadError = errorMessage(error)
        }
    }

    private func formattedDate(_ date: Date) -> String {
        airedOnFormatter.string(from: date)
    }

    private var airedOnFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

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
