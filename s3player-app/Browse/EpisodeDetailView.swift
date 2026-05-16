//
//  EpisodeDetailView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct EpisodeDetailView: View {
    let route: EpisodeRouteKey
    @ObservedObject var auth: AuthViewModel
    @EnvironmentObject var playback: PlaybackController
    @State private var state: LoadState<EpisodeDetail> = .idle
    @State private var savedProgress: ProgressResponse?
    @State private var summariesState: LoadState<[ChapterSummary]> = .idle
    @State private var expandedSummaries: Set<Int> = []
    @State private var markCompletedInFlight = false
    @State private var markCompletedError: String?
    private static let progressRefreshInterval: UInt64 = 15_000_000_000

    var body: some View {
        List {
            summarySection
            detailsSections
            chapterSummariesSection
        }
        .navigationTitle("Episode")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .appToolbar(auth: auth)
        .task(id: route.episode.id) {
            await load()
            await refreshProgressPeriodically()
        }
        .refreshable { await load() }
    }

    private var displayedEpisode: Episode {
        switch state {
        case .loaded(let detail):
            return detail.episode
        default:
            return route.episode
        }
    }

    private var displayedShow: ShowDetail {
        switch state {
        case .loaded(let detail):
            return detail.show
        default:
            return route.show
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayedShow.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)

                    Text(DateFormatter.sharedISODate.string(from: displayedEpisode.aired_on))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(displayedShow.station)
                    let slot = formatTimeSlot(displayedEpisode.time_slot)
                    if !slot.isEmpty {
                        Text("·")
                        Text(slot)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if isCurrentlyPlaying {
                    Label("Now Playing", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                } else {
                    playButton

                    if let savedPositionText {
                        Label(savedPositionText, systemImage: "clock.arrow.circlepath")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if showMarkCompletedButton {
                    markCompletedButton
                }

                if let markCompletedError {
                    Label(markCompletedError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var showMarkCompletedButton: Bool {
        playback.sessionState == .active && savedProgress?.completed != true
    }

    private var markCompletedButton: some View {
        Button {
            Task { await markCompleted() }
        } label: {
            HStack(spacing: 8) {
                if markCompletedInFlight {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle")
                }
                Text("Mark as completed")
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(markCompletedInFlight)
        .accessibilityLabel("Mark this episode as completed")
    }

    private func markCompleted() async {
        guard !markCompletedInFlight else { return }
        markCompletedInFlight = true
        markCompletedError = nil
        let episodeId = displayedEpisode.id
        let positionMs = savedProgress?.position_ms ?? 0
        let durationMs = savedProgress?.duration_ms
        let succeeded = await playback.markEpisodeCompleted(
            episodeId: episodeId,
            positionMs: positionMs,
            durationMs: durationMs
        )
        markCompletedInFlight = false
        if succeeded {
            await refreshProgress()
        } else {
            markCompletedError = "Couldn't mark this episode complete. Try again."
        }
    }

    private var isCurrentlyPlaying: Bool {
        playback.currentEpisode?.id == displayedEpisode.id && playback.sessionState == .active
    }

    private var playButton: some View {
        Button {
            playback.play(episode: displayedEpisode, show: displayedShow)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(playButtonTitle)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private var playButtonTitle: String {
        if let savedProgress, !savedProgress.completed, savedProgress.position_ms > 0 {
            return "Resume"
        }
        return "Play Episode"
    }

    private var savedPositionText: String? {
        guard let savedProgress, !savedProgress.completed, savedProgress.position_ms > 0 else {
            return nil
        }

        if let durationMs = savedProgress.duration_ms, durationMs > 0 {
            return "Saved position \(formatMs(savedProgress.position_ms)) / \(formatMs(durationMs))"
        }

        return "Saved position \(formatMs(savedProgress.position_ms))"
    }

    @ViewBuilder
    private var detailsSections: some View {
        switch state {
        case .idle, .loading:
            Section("Details") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading episode details…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section("Details") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        case .loaded(let detail):
            Section("Chapters") {
                if let chapters = detail.chapters, !chapters.isEmpty {
                    ForEach(chapters, id: \.self) { chapter in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chapter.title)
                                .font(.body)
                            Text("\(formatMs(chapter.start)) - \(formatMs(chapter.end))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } else {
                    Text("No chapter info available for this episode.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chapterSummariesSection: some View {
        switch summariesState {
        case .idle, .loading:
            Section("Chapter summaries") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading chapter summaries…")
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section("Chapter summaries") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await loadSummaries() } }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        case .loaded(let summaries) where summaries.isEmpty:
            EmptyView()
        case .loaded(let summaries):
            Section {
                ForEach(summaries) { summary in
                    chapterSummaryRow(summary)
                }
            } header: {
                HStack {
                    Text("Chapter summaries")
                    Spacer()
                    Text("\(summaries.count)")
                        .foregroundStyle(.secondary)
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func chapterSummaryRow(_ summary: ChapterSummary) -> some View {
        let isOpen = expandedSummaries.contains(summary.index)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isOpen { expandedSummaries.remove(summary.index) }
                else { expandedSummaries.insert(summary.index) }
            } label: {
                HStack {
                    Text(String(format: "Chapter %02d", summary.index))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Collapse summary" : "Expand summary")

            if isOpen {
                Text(summary.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            return
        }

        state = .loading
        savedProgress = nil
        do {
            async let detailRequest = client.getEpisodeDetail(episodeId: route.episode.id)
            async let progressRequest = client.getProgress(episodeId: route.episode.id)

            state = .loaded(try await detailRequest)

            do {
                savedProgress = try await progressRequest
            } catch APIError.unauthorized {
                auth.logout()
            } catch {
                savedProgress = nil
            }
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }

        await loadSummaries()
    }

    private func loadSummaries() async {
        guard let client = APIClient(auth: auth) else {
            summariesState = .failed("Not signed in.")
            return
        }
        summariesState = .loading
        do {
            let response = try await client.getChapterSummaries(episodeId: route.episode.id)
            summariesState = .loaded(response.summaries)
        } catch APIError.unauthorized {
            auth.logout()
        } catch APIError.notFound {
            summariesState = .loaded([])
        } catch {
            summariesState = .failed(errorMessage(error))
        }
    }

    private func refreshProgressPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.progressRefreshInterval)
            if Task.isCancelled { return }
            await refreshProgress()
        }
    }

    private func refreshProgress() async {
        guard let client = APIClient(auth: auth) else { return }
        do {
            // Background tick: keep prior savedProgress on transient errors so the
            // UI doesn't flicker between a known state and "not loaded yet".
            savedProgress = try await client.getProgress(episodeId: route.episode.id)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            // Transient: keep existing savedProgress.
        }
    }
}
