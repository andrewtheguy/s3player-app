//
//  MonthsView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

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
