//
//  BrowseViews.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

private enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)
}

struct StationsView: View {
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<[Station]> = .idle

    var body: some View {
        contentView
            .navigationTitle("Stations")
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(for: Station.self) { station in
                ShowsView(station: station.id, auth: auth)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .loaded(let stations) where stations.isEmpty:
            EmptyStateView(message: "No stations indexed yet.")
        case .loaded(let stations):
            List(stations) { station in
                NavigationLink(value: station) {
                    HStack {
                        Text(station.id)
                            .font(.body)
                        Spacer()
                        CountBadge(count: station.show_count)
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
            let response = try await client.listStations()
            state = .loaded(response.stations)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }
    }
}

struct ShowsView: View {
    let station: String
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<[Show]> = .idle

    var body: some View {
        contentView
            .navigationTitle(station)
            .task { await load() }
            .refreshable { await load() }
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
}

struct MonthRouteKey: Hashable {
    let show: ShowDetail
    let year: Int
    let month: Int
}

struct MonthsView: View {
    let show: ShowDetail
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<[Int: [MonthBucket]]> = .idle

    var body: some View {
        contentView
            .navigationTitle(show.name)
            .task { await load() }
            .refreshable { await load() }
            .navigationDestination(for: MonthRouteKey.self) { key in
                EpisodesView(show: key.show, year: key.year, month: key.month, auth: auth)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .loaded(let grouped) where grouped.isEmpty:
            EmptyStateView(message: "No episodes for this show yet.")
        case .loaded(let grouped):
            List {
                ForEach(grouped.keys.sorted(by: >), id: \.self) { year in
                    Section(String(year)) {
                        let months = (grouped[year] ?? []).sorted { $0.month > $1.month }
                        ForEach(months, id: \.self) { bucket in
                            NavigationLink(
                                value: MonthRouteKey(show: show, year: bucket.year, month: bucket.month)
                            ) {
                                HStack {
                                    Text(monthName(bucket.month))
                                    Spacer()
                                    CountBadge(count: bucket.episode_count)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func monthName(_ month: Int) -> String {
        String(format: "%02d", month)
    }

    private func load() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            return
        }
        state = .loading
        do {
            let response = try await client.listMonths(showId: show.id)
            let grouped = Dictionary(grouping: response.months, by: \.year)
            state = .loaded(grouped)
        } catch APIError.unauthorized {
            auth.logout()
        } catch {
            state = .failed(errorMessage(error))
        }
    }
}

struct EpisodeRouteKey: Hashable {
    let show: ShowDetail
    let episode: Episode
}

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
            .navigationDestination(for: EpisodeRouteKey.self) { key in
                PlayerView(episode: key.episode, show: key.show, auth: auth)
            }
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
                NavigationLink(value: EpisodeRouteKey(show: show, episode: episode)) {
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
        airedOnFormatter.string(from: date)
    }
}

private let airedOnFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private func errorMessage(_ error: Error) -> String {
    if let apiError = error as? APIError {
        return apiError.errorDescription ?? "Request failed."
    }
    return error.localizedDescription
}
