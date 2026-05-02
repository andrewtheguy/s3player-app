//
//  ContentView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import Combine
import SwiftUI

@MainActor
final class NavigationCoordinator: ObservableObject {
    @Published var path = NavigationPath()
}

struct ContentView: View {
    @ObservedObject var auth: AuthViewModel
    @StateObject private var playback: PlaybackController
    @StateObject private var navigation = NavigationCoordinator()

    init(auth: AuthViewModel) {
        self.auth = auth
        _playback = StateObject(wrappedValue: PlaybackController(auth: auth))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $navigation.path) {
                StationsView(auth: auth)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Sign Out") {
                                auth.logout()
                            }
                        }
                    }
            }
            if playback.currentEpisode != nil, let show = playback.currentShow {
                MiniNowPlayingBar(controller: playback, show: show)
            }
        }
        .environmentObject(playback)
        .environmentObject(navigation)
        .sheet(isPresented: $playback.isExpanded) {
            NowPlayingSheet(controller: playback)
                .environmentObject(navigation)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
    }
}

#Preview {
    ContentView(auth: AuthViewModel())
}
