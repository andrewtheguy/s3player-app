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
    @EnvironmentObject var navigation: NavigationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var scrubberProgress: Double = 0
    @State private var isScrubbing = false
    @State private var chapters: [Chapter] = []

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
                        episodeDetailsLink(show: show, episode: episode)
                    }
                    playbackControls
                    if controller.sessionState == .active {
                        progressView
                    }
                    if !chapters.isEmpty {
                        chaptersSection
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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        #if os(macOS)
                        Text("Done")
                            .font(.body.weight(.semibold))
                        #else
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                        #endif
                    }
                    .accessibilityLabel("Collapse player")
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
            .task(id: controller.currentEpisode?.id) {
                await loadChapters(for: controller.currentEpisode?.id)
            }
        }
    }

    private func loadChapters(for episodeId: Int?) async {
        guard let episodeId else {
            chapters = []
            return
        }
        guard let client = APIClient(auth: controller.auth) else {
            chapters = []
            return
        }
        do {
            let detail = try await client.getEpisodeDetail(episodeId: episodeId)
            chapters = detail.chapters ?? []
        } catch APIError.unauthorized {
            controller.auth.logout()
            chapters = []
        } catch {
            chapters = []
        }
    }

    private var chaptersSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                chapterRow(chapter)
                if index < chapters.count - 1 {
                    Divider()
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let elapsedMs = Int(player.elapsedTime * 1000)
        let isCurrent = elapsedMs >= chapter.start && elapsedMs < chapter.end
        let rightLabel = isCurrent
            ? "-\(formatMs(max(0, chapter.end - elapsedMs)))"
            : formatMs(chapter.end - chapter.start)

        return Button {
            controller.seek(toMilliseconds: chapter.start)
        } label: {
            HStack(spacing: 12) {
                Text(chapter.title.isEmpty ? formatMs(chapter.start) : chapter.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(rightLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metadata(show: ShowDetail, episode: Episode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(show.name)
                .font(.title2.bold())
            HStack(spacing: 8) {
                Text(DateFormatter.sharedISODate.string(from: episode.aired_on))
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

    private func episodeDetailsLink(show: ShowDetail, episode: Episode) -> some View {
        Button {
            openEpisodeDetail(show: show, episode: episode)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                Text("Show Episode Details")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityHint("Opens episode details and chapters")
    }

    private func openEpisodeDetail(show: ShowDetail, episode: Episode) {
        // Replace the stack so back from EpisodeDetail lands on the show's
        // month view (matching the drill-through and rail flows).
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: episode.aired_on)
        var path = NavigationPath()
        if let year = components.year, let month = components.month {
            path.append(MonthRouteKey(show: show, year: year, month: month))
        }
        path.append(EpisodeRouteKey(episode: episode, show: show))
        navigation.path = path
        dismiss()
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
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
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
