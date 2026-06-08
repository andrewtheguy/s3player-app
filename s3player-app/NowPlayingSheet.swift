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
    @State private var chapterSummaries: [ChapterSummary] = []
    @State private var expandedSummaries: Set<Int> = []

    init(controller: PlaybackController) {
        self.controller = controller
        self.player = controller.player
    }

    // Drive the chapters list off the controller's cached chapters so the sheet
    // renders chapters offline (hydrated from the snapshot at launch). The
    // server-fetched value is pushed back into the controller's cache.
    private var chapters: [Chapter] { controller.cachedChapters }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let show = controller.currentShow, let episode = controller.currentEpisode {
                        metadata(show: show, episode: episode)
                        episodeDetailsLink(show: show, episode: episode)
                    }
                    playbackControls
                    if player.playbackUnsupported {
                        unplayableBanner
                    } else if controller.replayConfirmNeeded {
                        replayConfirmBanner
                    }
                    if controller.sessionState == .active,
                       !controller.replayConfirmNeeded,
                       !player.playbackUnsupported {
                        progressView
                        if !chapters.isEmpty {
                            chaptersSection
                        }
                        if !chapterSummaries.isEmpty {
                            chapterSummariesSection
                        }
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
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.body.weight(.semibold))
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
                scrubberProgress = displayProgressFraction
            }
            .task(id: controller.currentEpisode?.id) {
                await loadChapters(for: controller.currentEpisode?.id)
                await loadChapterSummaries(for: controller.currentEpisode?.id)
            }
            .onChange(of: controller.sessionState) { _, newState in
                // Refetch chapters when the session is (re)claimed so any
                // server-side edits land at the same moment we sync position.
                guard newState == .active else { return }
                Task {
                    await loadChapters(for: controller.currentEpisode?.id)
                    await loadChapterSummaries(for: controller.currentEpisode?.id)
                }
            }
        }
    }

    private func loadChapters(for episodeId: Int?) async {
        guard let episodeId else {
            controller.updateCachedChapters([])
            return
        }
        guard let client = APIClient(auth: controller.auth) else { return }
        do {
            let detail = try await client.getEpisodeDetail(episodeId: episodeId)
            controller.updateCachedChapters(detail.chapters ?? [])
        } catch APIError.unauthorized {
            controller.auth.logout()
        } catch {
            // Transport / other failures: keep the cached chapters in place so
            // the offline sheet still renders the last-known list.
        }
    }

    private func loadChapterSummaries(for episodeId: Int?) async {
        guard let episodeId else {
            chapterSummaries = []
            expandedSummaries = []
            return
        }
        guard let client = APIClient(auth: controller.auth) else { return }
        do {
            let response = try await client.getChapterSummaries(episodeId: episodeId)
            chapterSummaries = response.summaries
            expandedSummaries.formIntersection(response.summaries.map(\.index))
        } catch APIError.unauthorized {
            controller.auth.logout()
        } catch {
            // Transient failures keep the prior list visible so the sheet still
            // renders summaries when offline after a successful first fetch.
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

    private var chapterSummariesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chapter summaries")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(chapterSummaries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(chapterSummaries.enumerated()), id: \.element.index) { offset, summary in
                    chapterSummaryRow(summary)
                    if offset < chapterSummaries.count - 1 {
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
    }

    private func chapterSummaryRow(_ summary: ChapterSummary) -> some View {
        let isOpen = expandedSummaries.contains(summary.index)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expandedSummaries.remove(summary.index) }
                else { expandedSummaries.insert(summary.index) }
            } label: {
                HStack(spacing: 12) {
                    Text(String(format: "Chapter %02d", summary.index))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapse summary" : "Expand summary")

            if isOpen {
                Text(summary.content)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let elapsedMs = Int(player.elapsedTime * 1000)
        let isCurrent = elapsedMs >= chapter.start && elapsedMs < chapter.end
        let chapterDurationMs = max(1, chapter.end - chapter.start)
        let chapterProgress = isCurrent
            ? min(1, max(0, Double(elapsedMs - chapter.start) / Double(chapterDurationMs)))
            : 0
        let rightLabel = isCurrent
            ? "-\(formatMs(max(0, chapter.end - elapsedMs)))"
            : formatMs(chapter.end - chapter.start)

        return Button {
            guard !isCurrent else { return }
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
            .background {
                if isCurrent {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.accentColor.opacity(0.15)
                            Color.accentColor.opacity(0.4)
                                .frame(width: geo.size.width * chapterProgress)
                        }
                    }
                }
            }
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
                if let format = controller.currentAudioFormat, !format.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(format.uppercased())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.secondary.opacity(0.15))
                        }
                        .accessibilityLabel("Audio format \(format.uppercased())")
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
        if controller.phase.isBusy {
            downloadProgressControls
        } else {
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
                if controller.needsResumeFromSnapshot {
                    Button { controller.resumeFromSnapshot() } label: {
                        Label("Resume", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
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
                        .disabled(
                            !player.hasLoadedAudio
                            || player.isLoading
                            || controller.replayConfirmNeeded
                            || player.playbackUnsupported
                        )

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
        }
    }

    @ViewBuilder
    private var downloadProgressControls: some View {
        VStack(spacing: 12) {
            HStack {
                Label(downloadStatusLabel, systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Cancel") { controller.cancelDownload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            ProgressView(value: downloadFraction)
                .progressViewStyle(.linear)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background.secondary)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var downloadFraction: Double {
        if case .downloading(let f) = controller.phase {
            return min(max(f, 0), 1)
        }
        return 0
    }

    private var downloadStatusLabel: String {
        switch controller.phase {
        case .preparing: return "Preparing…"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        default: return "Loading…"
        }
    }

    private var markCompletedButton: some View {
        Button {
            controller.markCompleted()
        } label: {
            Label("Mark as completed", systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(
            !player.hasLoadedAudio
            || player.isLoading
            || controller.replayConfirmNeeded
            || controller.sessionState != .active
            || player.playbackUnsupported
        )
        .accessibilityLabel("Mark this episode as completed")
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
                Text(player.formattedTime(displayElapsedSeconds))
                Spacer()
                Text(displayDurationText)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // Before the audio asset loads (fresh launch, pre-resume) the player reports
    // zero elapsed/duration. Fall back to the saved snapshot position so the
    // slider and time labels show where playback will resume instead of 0:00.

    private var displayProgressFraction: Double {
        if player.hasDuration { return player.progress }
        if let resume = controller.snapshotResumeSeconds,
           let duration = controller.snapshotDurationSeconds, duration > 0 {
            return min(max(resume / duration, 0), 1)
        }
        return 0
    }

    private var displayElapsedSeconds: Double {
        if player.hasDuration { return player.elapsedTime }
        return controller.snapshotResumeSeconds ?? player.elapsedTime
    }

    private var displayDurationText: String {
        if player.hasDuration { return player.formattedTime(player.duration) }
        if let duration = controller.snapshotDurationSeconds {
            return player.formattedTime(duration)
        }
        return "--:--"
    }

    private var unplayableBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cannot play this episode", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text("The audio file does not report a finite duration, so progress and completion can't be tracked. Playback is disabled.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
        }
    }

    private var replayConfirmBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Episode already completed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("You've finished this episode. Replay from the beginning to listen again — this resets the saved position and moves it back to Continue listening.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button { controller.confirmReplay() } label: {
                Label("Replay from beginning", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(controller.sessionState != .active)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.yellow.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
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
                HStack(spacing: 12) {
                    Label(player.statusMessage, systemImage: player.isLoading ? "hourglass" : "waveform")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer(minLength: 12)
                    if !controller.replayConfirmNeeded, !player.playbackUnsupported {
                        markCompletedButton
                    }
                }
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
