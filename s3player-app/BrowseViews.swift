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
    @State private var inProgressState: LoadState<[RecentEpisode]> = .idle
    @State private var recentState: LoadState<[RecentEpisode]> = .idle
    @State private var didInitialLoad = false
    private static let railRefreshInterval: UInt64 = 15_000_000_000

    var body: some View {
        List {
            Section("Continue listening") {
                railSectionContent(
                    state: inProgressState,
                    emptyMessage: "Nothing in progress yet."
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section("Recently played") {
                railSectionContent(
                    state: recentState,
                    emptyMessage: "No recently played episodes yet."
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
        .navigationDestination(for: Station.self) { station in
            ShowsView(station: station.id, auth: auth)
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
            RecentRail(entries: entries)
        }
    }

    private func loadAll() async {
        guard let client = APIClient(auth: auth) else {
            state = .failed("Not signed in.")
            inProgressState = .failed("Not signed in.")
            recentState = .failed("Not signed in.")
            return
        }
        if case .loaded = state {} else { state = .loading }
        if case .loaded = inProgressState {} else { inProgressState = .loading }
        if case .loaded = recentState {} else { recentState = .loading }
        async let stationsResult = client.listStations()
        async let inProgressResult = client.listInProgress()
        async let recentResult = client.listRecent()

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
            inProgressState = .loaded(try await inProgressResult.episodes)
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
        } catch {
            recentState = .failed(errorMessage(error))
        }
    }

    private func loadRails(showLoading: Bool = false) async {
        guard let client = APIClient(auth: auth) else { return }
        if showLoading {
            inProgressState = .loading
            recentState = .loading
        }
        async let inProgressResult = client.listInProgress()
        async let recentResult = client.listRecent()

        do {
            inProgressState = .loaded(try await inProgressResult.episodes)
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
        } catch {
            if showLoading {
                recentState = .failed(errorMessage(error))
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

struct EpisodeRouteKey: Hashable {
    let episode: Episode
    let show: ShowDetail
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
            .navigationDestination(for: EpisodeRouteKey.self) { key in
                EpisodeDetailView(route: key, auth: auth)
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

    var body: some View {
        List {
            summarySection
            detailsSections
        }
        .navigationTitle("Episode")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: route.episode.id) { await load() }
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

                playButton

                if let savedPositionText {
                    Label(savedPositionText, systemImage: "clock.arrow.circlepath")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
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
    }
}

private struct RecentRail: View {
    let entries: [RecentEpisode]

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 12) {
                    ForEach(entries) { entry in
                        RecentCard(entry: entry)
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
    @EnvironmentObject var playback: PlaybackController

    var body: some View {
        Button {
            let synthesized = entry.synthesizedEpisodeAndShow()
            playback.play(episode: synthesized.episode, show: synthesized.show)
        } label: {
            content
        }
        .buttonStyle(.plain)
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
        } else if entry.completed {
            Text("Played")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        } else if let durationMs = entry.duration_ms, durationMs > 0 {
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
