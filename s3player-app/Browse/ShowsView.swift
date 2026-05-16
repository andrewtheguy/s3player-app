//
//  ShowsView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct ShowsView: View {
    let station: String
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<[Show]> = .idle

    var body: some View {
        contentView
            .navigationTitle(station)
            .task { await load() }
            .refreshable { await load() }
            .appToolbar(auth: auth)
            .navigationDestination(for: Show.self) { show in
                MonthsView(
                    show: ShowDetail(
                        id: show.id,
                        station: station,
                        name: show.name,
                        episode_count: show.episode_count
                    ),
                    auth: auth
                )
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .loaded(let shows) where shows.isEmpty:
            EmptyStateView(message: "No shows for this station.")
        case .loaded(let shows):
            List(shows) { show in
                NavigationLink(value: show) {
                    HStack {
                        Text(show.name)
                            .font(.body)
                        Spacer()
                        FavoriteStarButton(isFavorite: show.is_favorite) {
                            toggleFavorite(show)
                        }
                        CountBadge(count: show.episode_count)
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            return
        }
        state = .loading
        do {
            let response = try await client.listShows(station: station)
            state = .loaded(response.shows)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }
    }

    private func toggleFavorite(_ show: Show) {
        guard case .loaded(let shows) = state else { return }
        let wasFavorite = show.is_favorite
        let updated = shows.map { existing -> Show in
            guard existing.id == show.id else { return existing }
            return Show(
                id: existing.id,
                name: existing.name,
                episode_count: existing.episode_count,
                is_favorite: !wasFavorite
            )
        }
        state = .loaded(updated)

        Task { [showId = show.id, wasFavorite] in
            guard let client = APIClient(auth: auth) else { return }
            do {
                if wasFavorite {
                    try await client.removeFavorite(showId: showId)
                } else {
                    try await client.addFavorite(showId: showId)
                }
            } catch APIError.unauthorized {
                auth.logout()
            } catch {
                if case .loaded(let current) = state {
                    let reverted = current.map { existing -> Show in
                        guard existing.id == showId else { return existing }
                        return Show(
                            id: existing.id,
                            name: existing.name,
                            episode_count: existing.episode_count,
                            is_favorite: wasFavorite
                        )
                    }
                    state = .loaded(reverted)
                }
                print("Failed to toggle favorite for show \(showId): \(error)")
            }
        }
    }
}

private struct FavoriteStarButton: View {
    let isFavorite: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.body)
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        // .borderless lets the tap fall through to just the button (not the whole row),
        // which keeps the surrounding NavigationLink working for a tap on the row body.
        .buttonStyle(.borderless)
        .accessibilityLabel(isFavorite ? "Unfavorite show" : "Favorite show")
    }
}
