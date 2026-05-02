//
//  s3player_appApp.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

@main
struct s3player_appApp: App {
    @StateObject private var auth = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            if auth.isAuthenticated {
                if auth.isValidatingPlayerSession {
                    SessionValidationView()
                } else {
                    ContentView(auth: auth)
                }
            } else {
                LoginView(auth: auth)
            }
        }
    }
}

private struct SessionValidationView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Restoring playback session…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
