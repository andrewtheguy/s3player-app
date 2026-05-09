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

private enum RailKind {
    case inProgress
    case completed
}

struct StationsView: View {
    @ObservedObject var auth: AuthViewModel
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
        .refreshable { await loadAll() }
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

struct MonthRouteKey: Hashable {
    let show: ShowDetail
    let year: Int
    let month: Int
}

struct EpisodeRouteKey: Hashable {
    let episode: Episode
    let show: ShowDetail
}

struct ShowRecentEpisodesRouteKey: Hashable {
    let showId: Int
    let fallbackName: String
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
            .appToolbar(auth: auth)
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
                ForEach(grouped.keys.sorted(by: <), id: \.self) { year in
                    Section(String(year)) {
                        let months = (grouped[year] ?? []).sorted { $0.month < $1.month }
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

private struct EpisodeDetailView: View {
    let route: EpisodeRouteKey
    @ObservedObject var auth: AuthViewModel
    @EnvironmentObject var playback: PlaybackController
    @State private var state: LoadState<EpisodeDetail> = .idle
    @State private var savedProgress: ProgressResponse?
    @State private var summariesState: LoadState<[ChapterSummary]> = .idle
    @State private var expandedSummaries: Set<Int> = []
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
            }
            .padding(.vertical, 8)
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

struct ShowRecentEpisodesView: View {
    let showId: Int
    let fallbackName: String
    @ObservedObject var auth: AuthViewModel
    @State private var state: LoadState<RecentShowEpisodesResponse> = .idle

    var body: some View {
        contentView
            .navigationTitle(loadedShowName ?? fallbackName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await load() }
            .refreshable { await load() }
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

extension RecentEpisode {
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

private let lastPlayedISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let lastPlayedFallbackFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

private func parseLastPlayed(_ iso: String) -> Date? {
    if let date = lastPlayedISOFormatter.date(from: iso) { return date }
    return lastPlayedFallbackFormatter.date(from: iso)
}

private func formatRelativeLastPlayed(_ iso: String) -> String {
    guard let date = parseLastPlayed(iso) else { return "" }
    return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}

private func lastPlayedDate(for entry: RecentEpisode) -> Date {
    parseLastPlayed(entry.last_played_at) ?? .distantPast
}

func formatMs(_ ms: Int) -> String {
    let totalSeconds = max(0, ms) / 1000
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

private var railCardBackground: Color {
    #if os(macOS)
    Color(NSColor.controlBackgroundColor)
    #else
    Color(.secondarySystemGroupedBackground)
    #endif
}

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
