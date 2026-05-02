//
//  MiniNowPlayingBar.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct MiniNowPlayingBar: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var player: AudioPlayerViewModel

    init(controller: PlaybackController) {
        self.controller = controller
        self.player = controller.player
    }

    var body: some View {
        if let episode = controller.currentEpisode, let show = controller.currentShow {
            content(episode: episode, show: show)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(episode: Episode, show: ShowDetail) -> some View {
        VStack(spacing: 0) {
            progressBar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle(for: episode))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { controller.expand() }

                actionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.secondary.opacity(0.18)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * progressFraction)
            }
        }
        .frame(height: 2)
    }

    private var progressFraction: Double {
        guard player.hasDuration else { return 0 }
        return min(max(player.progress, 0), 1)
    }

    private func subtitle(for episode: Episode) -> String {
        let date = DateFormatter.sharedISODate.string(from: episode.aired_on)
        let slot = formatTimeSlot(episode.time_slot)
        return slot.isEmpty ? date : "\(date) · \(slot)"
    }

    @ViewBuilder
    private var actionButton: some View {
        switch controller.sessionState {
        case .active:
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasLoadedAudio || player.isLoading)
        case .inactive:
            Button {
                controller.requestActivate()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        case .displaced:
            Button {
                controller.requestTakeOver()
            } label: {
                Image(systemName: "arrow.uturn.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        case .activating:
            ProgressView()
                .frame(width: 44, height: 44)
        }
    }
}
