//
//  StationsView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

private enum RailKind {
    case inProgress
    case completed
}

struct StationsView: View {
    @ObservedObject var auth: AuthViewModel
    @EnvironmentObject private var playback: PlaybackController
    @State private var state: LoadState<[Station]> = .idle
    @State private var inProgressState: LoadState<[RecentEpisode]> = .idle
    @State private var recentState: LoadState<[RecentEpisode]> = .idle
    @State private var favoritesState: LoadState<[FavoriteShow]> = .idle
    @State private var didInitialLoad = false
    // Episodes whose DELETE /progress request is still in flight. The rail
    // refreshers filter these out so an in-flight delete cannot flicker the
    // dismissed card back into view if the server hasn't yet committed the row
    // removal.
    @State private var pendingDeletions: Set<Int> = []
    @State private var isRefreshing = false
    private static let railRefreshInterval: UInt64 = 15_000_000_000

    var body: some View {
        List {
            if case .loaded(let favorites) = favoritesState, !favorites.isEmpty {
                Section("Favorites") {
                    FavoritesRail(entries: favorites)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section("Continue listening") {
                railSectionContent(
                    state: inProgressState,
                    kind: .inProgress,
                    emptyMessage: "Nothing in progress yet."
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Recently Completed") {
                railSectionContent(
                    state: recentState,
                    kind: .completed,
                    emptyMessage: "No recently completed episodes yet."
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Stations") {
                stationsSectionContent
            }
        }
        .navigationTitle("Stations")
        .task {
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await loadAll()
        }
        .task {
            await refreshRailsPeriodically()
        }
        .onAppear {
            if didInitialLoad {
                Task { await loadRails() }
            }
        }
        // NavigationStack does not re-fire .onAppear on the root when the user
        // pops back to it, so an episode completed inside a pushed view would
        // otherwise wait up to railRefreshInterval to show up here. Refresh
        // immediately whenever a completion lands or a new episode is started
        // (the latter ticks once per episode, not on every 5s progress save).
        .onChange(of: playback.completionTick) { _, _ in
            if didInitialLoad {
                Task { await loadRails() }
            }
        }
        .onChange(of: playback.currentEpisodeTick) { _, _ in
            if didInitialLoad {
                Task { await loadRails() }
            }
        }
        .refreshable {
            isRefreshing = true
            await loadAll()
            isRefreshing = false
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task {
                        isRefreshing = true
                        await loadAll()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .appToolbar(auth: auth)
        .navigationDestination(for: Station.self) { station in
            ShowsView(station: station.id, auth: auth)
        }
        .navigationDestination(for: MonthRouteKey.self) { key in
            EpisodesView(show: key.show, year: key.year, month: key.month, auth: auth)
        }
        .navigationDestination(for: EpisodeRouteKey.self) { key in
            EpisodeDetailView(route: key, auth: auth)
        }
        .navigationDestination(for: ShowRecentEpisodesRouteKey.self) { key in
            ShowRecentEpisodesView(showId: key.showId, fallbackName: key.fallbackName, auth: auth)
        }
    }

    @ViewBuilder
    private var stationsSectionContent: some View {
        switch state {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Button("Retry") { Task { await loadAll() } }
                    .buttonStyle(.bordered)
            }
        case .loaded(let stations) where stations.isEmpty:
            Text("No stations indexed yet.")
                .foregroundStyle(.secondary)
        case .loaded(let stations):
            ForEach(stations) { station in
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

    @ViewBuilder
    private func railSectionContent(
        state: LoadState<[RecentEpisode]>,
        kind: RailKind,
        emptyMessage: String
    ) -> some View {
        switch state {
        case .idle, .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(minHeight: 88)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Retry") { Task { await loadRails(showLoading: true) } }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        case .loaded(let entries) where entries.isEmpty:
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        case .loaded(let entries):
            RecentRail(
                entries: entries,
                kind: kind,
                onRemove: kind == .inProgress ? { episode in removeInProgress(episode) } : nil
            )
        }
    }

    private func loadAll() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            inProgressState = .failed("Not signed in.")
            recentState = .failed("Not signed in.")
            favoritesState = .failed("Not signed in.")
            return
        }
        if case .loaded = state {} else { state = .loading }
        if case .loaded = inProgressState {} else { inProgressState = .loading }
        if case .loaded = recentState {} else { recentState = .loading }
        if case .loaded = favoritesState {} else { favoritesState = .loading }
        async let stationsResult = client.listStations()
        async let inProgressResult = client.listInProgress()
        async let recentResult = client.listRecentCompleted()
        async let favoritesResult = client.listFavorites()

        do {
            let stations = try await stationsResult
            state = .loaded(stations.stations)
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            state = .failed(errorMessage(error))
        }

        do {
            inProgressState = .loaded(applyPendingDeletions(try await inProgressResult.episodes))
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            inProgressState = .failed(errorMessage(error))
        }

        do {
            recentState = .loaded(try await recentResult.episodes)
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            recentState = .failed(errorMessage(error))
        }

        do {
            favoritesState = .loaded(try await favoritesResult.favorites)
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            favoritesState = .failed(errorMessage(error))
        }
    }

    private func loadRails(showLoading: Bool = false) async {
        guard let client = APIClient(auth: auth) else { return }
        if showLoading {
            inProgressState = .loading
            recentState = .loading
            favoritesState = .loading
        }
        async let inProgressResult = client.listInProgress()
        async let recentResult = client.listRecentCompleted()
        async let favoritesResult = client.listFavorites()

        do {
            inProgressState = .loaded(applyPendingDeletions(try await inProgressResult.episodes))
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            // User-initiated retry surfaces the error so the rail can show another Retry button;
            // background refreshes keep prior loaded values rather than overwriting them.
            if showLoading {
                inProgressState = .failed(errorMessage(error))
            }
        }

        do {
            recentState = .loaded(try await recentResult.episodes)
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            if showLoading {
                recentState = .failed(errorMessage(error))
            }
        }

        do {
            favoritesState = .loaded(try await favoritesResult.favorites)
        } catch APIError.unauthorized {
            auth.logout()
            return
        } catch {
            if showLoading {
                favoritesState = .failed(errorMessage(error))
            }
        }
    }

    private func refreshRailsPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.railRefreshInterval)
            if Task.isCancelled { return }
            await loadRails()
        }
    }

    private func applyPendingDeletions(_ entries: [RecentEpisode]) -> [RecentEpisode] {
        guard !pendingDeletions.isEmpty else { return entries }
        return entries.filter { !pendingDeletions.contains($0.id) }
    }

    private func removeInProgress(_ episode: RecentEpisode) {
        guard case .loaded(let episodes) = inProgressState else { return }
        guard episodes.contains(where: { $0.id == episode.id }) else { return }

        pendingDeletions.insert(episode.id)
        inProgressState = .loaded(episodes.filter { $0.id != episode.id })

        Task { [episode] in
            guard let client = APIClient(auth: auth) else {
                pendingDeletions.remove(episode.id)
                return
            }
            do {
                try await client.deleteProgress(episodeId: episode.id)
                pendingDeletions.remove(episode.id)
            } catch APIError.unauthorized {
                pendingDeletions.remove(episode.id)
                auth.logout()
            } catch {
                pendingDeletions.remove(episode.id)
                if case .loaded(let current) = inProgressState {
                    let restored = (current + [episode])
                        .sorted { lastPlayedDate(for: $0) > lastPlayedDate(for: $1) }
                    inProgressState = .loaded(restored)
                }
                print("Failed to remove from Continue listening: \(error)")
            }
        }
    }
}

private struct FavoritesRail: View {
    let entries: [FavoriteShow]

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 12) {
                    ForEach(entries) { entry in
                        FavoriteCard(entry: entry)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 146)
    }
}

private struct FavoriteCard: View {
    let entry: FavoriteShow
    @EnvironmentObject var navigation: NavigationCoordinator

    var body: some View {
        Button {
            navigation.path.append(
                ShowRecentEpisodesRouteKey(showId: entry.id, fallbackName: entry.name)
            )
        } label: {
            content
        }
        .buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.station.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(entry.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(entry.episode_count) \(entry.episode_count == 1 ? "episode" : "episodes")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let latest = entry.latest_aired_on {
                Text("Latest: \(DateFormatter.sharedISODate.string(from: latest))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 240, height: 130, alignment: .topLeading)
        .background(railCardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RecentRail: View {
    let entries: [RecentEpisode]
    let kind: RailKind
    let onRemove: ((RecentEpisode) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 12) {
                    ForEach(entries) { entry in
                        RecentCard(
                            entry: entry,
                            kind: kind,
                            onRemove: onRemove.map { handler in { handler(entry) } }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 146)
    }
}

private struct RecentCard: View {
    let entry: RecentEpisode
    let kind: RailKind
    let onRemove: (() -> Void)?
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var navigation: NavigationCoordinator

    var body: some View {
        Button {
            let synthesized = entry.synthesizedEpisodeAndShow()
            // Push month then episode so the back button leads to the show's
            // month view (matching the drill-through path Stations → Shows →
            // Months → Episodes → EpisodeDetail).
            let calendar = Calendar(identifier: .gregorian)
            let components = calendar.dateComponents([.year, .month], from: entry.aired_on)
            if let year = components.year, let month = components.month {
                navigation.path.append(
                    MonthRouteKey(show: synthesized.show, year: year, month: month)
                )
            }
            navigation.path.append(
                EpisodeRouteKey(episode: synthesized.episode, show: synthesized.show)
            )
        } label: {
            content
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                removeButton(action: onRemove)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.show_name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(DateFormatter.sharedISODate.string(from: entry.aired_on))
                let slot = formatTimeSlot(entry.time_slot)
                if !slot.isEmpty {
                    Text("·")
                    Text(slot)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 240, height: 130, alignment: .topLeading)
        .background(railCardBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var footer: some View {
        if isNowPlaying {
            Label("Now Playing", systemImage: "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        } else if kind == .inProgress {
            if let durationMs = entry.duration_ms, durationMs > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(
                        value: Double(min(entry.position_ms, durationMs)),
                        total: Double(durationMs)
                    )
                    .progressViewStyle(.linear)
                    Text("\(formatMs(entry.position_ms)) / \(formatMs(durationMs))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            let relative = formatRelativeLastPlayed(entry.last_played_at)
            Text(relative.isEmpty ? "Completed" : "Completed · \(relative)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Remove \(entry.show_name) from Continue listening")
    }

    private var isNowPlaying: Bool {
        playback.currentEpisode?.id == entry.id && playback.sessionState == .active
    }
}

private extension RecentEpisode {
    func synthesizedEpisodeAndShow() -> (episode: Episode, show: ShowDetail) {
        // PlaybackController only reads episode.id / aired_on / time_slot and show.name,
        // so the unset fields below are safe placeholders for the rail-driven entry path.
        let show = ShowDetail(
            id: show_id,
            station: station,
            name: show_name,
            episode_count: 0
        )
        let episode = Episode(
            id: id,
            aired_on: aired_on,
            time_slot: time_slot,
            s3_key: "",
            chapters: nil
        )
        return (episode, show)
    }
}

private func lastPlayedDate(for entry: RecentEpisode) -> Date {
    parseLastPlayed(entry.last_played_at) ?? .distantPast
}

private var railCardBackground: Color {
    #if os(macOS)
    Color(NSColor.controlBackgroundColor)
    #else
    Color(.secondarySystemGroupedBackground)
    #endif
}
