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

private struct AppToolbarModifier: ViewModifier {
    @ObservedObject var auth: AuthViewModel
    @EnvironmentObject var navigation: NavigationCoordinator
    @State private var confirmSignOut = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !navigation.path.isEmpty {
                        Button {
                            navigation.path = NavigationPath()
                        } label: {
                            Label("Home", systemImage: "house")
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(role: .destructive) {
                            confirmSignOut = true
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .confirmationDialog(
                "Sign out?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    auth.logout()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You'll need to enter the password again to sign back in.")
            }
    }
}

extension View {
    func appToolbar(auth: AuthViewModel) -> some View {
        modifier(AppToolbarModifier(auth: auth))
    }
}

struct ContentView: View {
    @ObservedObject var auth: AuthViewModel
    @ObservedObject var playback: PlaybackController
    @StateObject private var navigation = NavigationCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $navigation.path) {
                StationsView(auth: auth)
            }
            MiniNowPlayingBar(controller: playback)
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
    let auth = AuthViewModel()
    return ContentView(auth: auth, playback: PlaybackController(auth: auth))
}
