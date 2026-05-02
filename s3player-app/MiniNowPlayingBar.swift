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
    let show: ShowDetail

    init(controller: PlaybackController, show: ShowDetail) {
        self.controller = controller
        self.player = controller.player
        self.show = show
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
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

                sessionStatusBadge
                actionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.background, ignoresSafeAreaEdges: .bottom)
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

    private var sessionStatusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(sessionStatusColor)
                .frame(width: 6, height: 6)
            Text(sessionStatusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(sessionStatusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(sessionStatusColor.opacity(0.12), in: Capsule())
    }

    private var sessionStatusText: String {
        switch controller.sessionState {
        case .active: return "Active"
        case .activating: return "Activating"
        case .inactive: return "Inactive"
        case .displaced: return "Displaced"
        }
    }

    private var sessionStatusColor: Color {
        switch controller.sessionState {
        case .active: return .green
        case .activating: return .yellow
        case .inactive: return .secondary
        case .displaced: return .orange
        }
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
