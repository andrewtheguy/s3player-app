//
//  BrowseSupport.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

enum LoadState<T> {
    case idle
    case loading
    case loaded(T)
    case failed(String)
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

struct CountBadge: View {
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

struct EmptyStateView: View {
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

struct ErrorStateView: View {
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

func parseLastPlayed(_ iso: String) -> Date? {
    if let date = lastPlayedISOFormatter.date(from: iso) { return date }
    return lastPlayedFallbackFormatter.date(from: iso)
}

func formatRelativeLastPlayed(_ iso: String) -> String {
    guard let date = parseLastPlayed(iso) else { return "" }
    return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}
