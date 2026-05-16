//
//  ShowRecentEpisodesView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct ShowRecentEpisodesView: View {
    let showId: Int
    let fallbackName: String
    @ObservedObject var auth: AuthViewModel
    @EnvironmentObject var playback: PlaybackController
    @State private var state: LoadState<RecentShowEpisodesResponse> = .idle
    @State private var didInitialLoad = false

    var body: some View {
        contentView
            .navigationTitle(loadedShowName ?? fallbackName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                await load()
                didInitialLoad = true
            }
            .refreshable { await load() }
            // Episode rows show position / completed status from the catalog
            // response. When a completion lands (either via the now-playing
            // sheet, the detail-view button, or a queued flush) the rail
            // refreshes immediately instead of waiting for a manual reload.
            // Gated on didInitialLoad so a completionTick bump mid-navigation
            // can't race the .task's initial load.
            .onChange(of: playback.completionTick) { _, _ in
                guard didInitialLoad else { return }
                Task { await load() }
            }
            .appToolbar(auth: auth)
    }

    private var loadedShowName: String? {
        if case .loaded(let response) = state { return response.show.name }
        return nil
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .loaded(let response) where response.episodes.isEmpty:
            EmptyStateView(message: "No episodes for this show yet.")
        case .loaded(let response):
            List(response.episodes) { episode in
                NavigationLink(value: routeKey(for: episode, show: response.show)) {
                    ShowEpisodeRow(episode: episode)
                }
            }
        }
    }

    private func routeKey(for episode: ShowEpisode, show: ShowDetail) -> EpisodeRouteKey {
        // ShowEpisode lacks s3_key/chapters; EpisodeDetailView refetches via
        // getEpisodeDetail and shows the placeholder Episode only during the
        // initial loading window. Same pattern as RecentEpisode.synthesizedEpisodeAndShow.
        let synthesizedEpisode = Episode(
            id: episode.id,
            aired_on: episode.aired_on,
            time_slot: episode.time_slot,
            s3_key: "",
            chapters: nil
        )
        return EpisodeRouteKey(episode: synthesizedEpisode, show: show)
    }

    private func load() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            return
        }
        if case .loaded = state {} else { state = .loading }
        do {
            let response = try await client.listRecentShowEpisodes(showId: showId)
            state = .loaded(response)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }
    }
}

private struct ShowEpisodeRow: View {
    let episode: ShowEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(DateFormatter.sharedISODate.string(from: episode.aired_on))
                    .font(.body)
                let slot = formatTimeSlot(episode.time_slot)
                if !slot.isEmpty {
                    Text(slot)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            statusView
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusView: some View {
        if let durationMs = episode.duration_ms,
           !episode.completed,
           episode.position_ms > 0,
           durationMs > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(min(episode.position_ms, durationMs)),
                    total: Double(durationMs)
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 180)
                Text("\(formatMs(episode.position_ms)) / \(formatMs(durationMs))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if episode.completed {
            let relative = episode.last_played_at.flatMap(formatRelativeOrNil) ?? ""
            Text(relative.isEmpty ? "Completed" : "Completed · \(relative)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private func formatRelativeOrNil(_ iso: String) -> String? {
    let result = formatRelativeLastPlayed(iso)
    return result.isEmpty ? nil : result
}
