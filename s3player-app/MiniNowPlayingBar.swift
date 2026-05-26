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
        VStack(spacing: 0) {
            Divider()
            if controller.currentEpisode != nil {
                progressBar
            }
            HStack(spacing: 12) {
                metadataBlock

                sessionStatusBadge
                actionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.background, ignoresSafeAreaEdges: .bottom)
    }

    @ViewBuilder
    private var metadataBlock: some View {
        if let show = controller.currentShow {
            Button {
                controller.expand()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(controller.replayConfirmNeeded ? "Completed" : "Now Playing")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.up")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(controller.replayConfirmNeeded ? .green : .secondary)

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
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("No episode loaded")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(emptyStateHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyStateHint: String {
        switch controller.sessionState {
        case .inactive: return "Take over to start listening on this device"
        case .displaced: return "Another device is playing — take over to listen here"
        case .activating: return "Connecting…"
        case .active: return "Pick an episode to start"
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
        if case .downloading(let fraction) = controller.phase {
            return min(max(fraction, 0), 1)
        }
        guard player.hasDuration else { return 0 }
        return min(max(player.progress, 0), 1)
    }

    private var progressText: String {
        if controller.replayConfirmNeeded {
            return "Open player to replay"
        }
        switch controller.phase {
        case .preparing:
            return "Preparing…"
        case .downloading(let fraction):
            return "Downloading \(Int(fraction * 100))%"
        default:
            break
        }
        guard player.hasDuration else { return "--:-- / --:--" }
        return "\(player.formattedTime(player.elapsedTime)) / \(player.formattedTime(player.duration))"
    }

    @ViewBuilder
    private var sessionStatusBadge: some View {
        if controller.isOffline {
            HStack(spacing: 4) {
                Image(systemName: "wifi.slash")
                    .font(.caption2.weight(.semibold))
                Text("Offline")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.12), in: Capsule())
        } else {
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
        if controller.phase.isBusy {
            ProgressView()
                .frame(width: 44, height: 44)
        } else {
            switch controller.sessionState {
            case .active:
                if controller.replayConfirmNeeded {
                    Button {
                        controller.expand()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Episode completed — open player to replay")
                } else {
                    Button {
                        if player.hasLoadedAudio {
                            controller.togglePlayback()
                        } else if controller.currentEpisode != nil {
                            controller.resumeFromSnapshot()
                        }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(player.isLoading || (!player.hasLoadedAudio && controller.currentEpisode == nil))
                }
            case .inactive, .displaced:
                Button {
                    controller.requestClaimSession()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.right")
                            .font(.caption.weight(.bold))
                        Text("Take Over")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.sessionState == .displaced ? .orange : .accentColor)
                .controlSize(.small)
                .accessibilityLabel("Take over playback session")
            case .activating:
                ProgressView()
                    .frame(width: 44, height: 44)
            }
        }
    }
}
