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
                if auth.isValidatingPlayerSession || auth.playerSessionValidationError != nil {
                    SessionValidationView(auth: auth)
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
    @ObservedObject var auth: AuthViewModel

    var body: some View {
        VStack(spacing: 24) {
            if let error = auth.playerSessionValidationError {
                failureView(message: error)
            } else {
                progressView
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Restoring playback session…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Couldn't restore your playback session")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: auth.retryPlayerSessionValidation) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.isValidatingPlayerSession)

                Button(action: auth.clearAndContinuePlayerSession) {
                    Label("Clear and Continue", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: 320)
        }
    }
}
