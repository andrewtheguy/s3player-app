//
//  EpisodesView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct EpisodesView: View {
    let show: ShowDetail
    let year: Int
    let month: Int
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<[Episode]> = .idle

    var body: some View {
        contentView
            .navigationTitle(monthTitle)
            .task { await load() }
            .refreshable { await load() }
            .appToolbar(auth: auth)
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .loaded(let episodes) where episodes.isEmpty:
            EmptyStateView(message: "No episodes in this month.")
        case .loaded(let episodes):
            List(episodes) { episode in
                NavigationLink(value: EpisodeRouteKey(episode: episode, show: show)) {
                    EpisodeRow(episode: episode)
                }
            }
        }
    }

    private var monthTitle: String {
        String(format: "%d-%02d", year, month)
    }

    private func load() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            return
        }
        state = .loading
        do {
            let response = try await client.listEpisodes(showId: show.id, year: year, month: month)
            state = .loaded(response.episodes)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formattedDate(episode.aired_on))
                .font(.body)
            HStack(spacing: 8) {
                let slot = formatTimeSlot(episode.time_slot)
                if !slot.isEmpty {
                    Text(slot)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let chapters = episode.chapters, !chapters.isEmpty {
                    Text("\(chapters.count) chapter\(chapters.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        DateFormatter.sharedISODate.string(from: date)
    }
}
