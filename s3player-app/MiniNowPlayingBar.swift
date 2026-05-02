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
        if controller.currentEpisode != nil, let show = controller.currentShow {
            content(show: show)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(show: ShowDetail) -> some View {
        VStack(spacing: 0) {
            progressBar
            HStack(spacing: 12) {
                Button {
                    controller.expand()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("Now Playing")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.secondary)

                        Text(show.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(progressText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open now playing")
                .accessibilityHint("Expands the full player")

                actionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
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

    private var progressText: String {
        guard player.hasDuration else { return "--:-- / --:--" }
        return "\(player.formattedTime(player.elapsedTime)) / \(player.formattedTime(player.duration))"
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
