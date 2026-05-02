//
//  NowPlayingSheet.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct NowPlayingSheet: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scrubberProgress: Double = 0
    @State private var isScrubbing = false

    init(controller: PlaybackController) {
        self.controller = controller
        self.player = controller.player
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let show = controller.currentShow, let episode = controller.currentEpisode {
                        metadata(show: show, episode: episode)
                    }
                    playbackControls
                    if controller.sessionState == .active {
                        progressView
                    }
                    statusView
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
            .navigationTitle(controller.currentShow?.name ?? "Now Playing")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(groupedBackground)
            .onChange(of: player.progress) { _, newProgress in
                guard !isScrubbing else { return }
                scrubberProgress = newProgress
            }
            .onAppear {
                scrubberProgress = player.progress
            }
        }
    }

    private func metadata(show: ShowDetail, episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(show.name)
                .font(.title2.bold())
            HStack(spacing: 8) {
                Text(airedOnFormatter.string(from: episode.aired_on))
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
        switch controller.sessionState {
        case .displaced:
            Button { controller.requestTakeOver() } label: {
                Label("Take Over Playback", systemImage: "arrow.uturn.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.orange)
        case .inactive:
            Button { controller.requestActivate() } label: {
                Label("Start Playback", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .activating:
            Button {} label: {
                Label("Connecting…", systemImage: "hourglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)
        case .active:
            HStack(spacing: 16) {
                Button { controller.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!player.hasDuration)

                Button { controller.togglePlayback() } label: {
                    Label(
                        player.isPlaying ? "Pause" : "Play",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!player.hasLoadedAudio || player.isLoading)

                Button { controller.skip(by: 30) } label: {
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
                        controller.seek(toProgress: scrubberProgress)
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
            if let loadError = controller.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            } else if controller.sessionState == .displaced {
                Label("Another device is playing. Take over to continue.", systemImage: "arrow.uturn.right")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            } else if controller.sessionState == .inactive {
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

    private var groupedBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }
}
