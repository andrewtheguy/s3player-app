//
//  ContentView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioPlayerViewModel()
    @State private var scrubberProgress = 0.0
    @State private var isScrubbing = false
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    urlEntry
                    playbackControls
                    progressView
                    statusView
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("S3 Player")
            .background(groupedBackground)
            .onChange(of: player.progress) { _, newProgress in
                guard !isScrubbing else { return }
                scrubberProgress = newProgress
            }
            .onDisappear {
                player.stop()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio URL Player")
                .font(.largeTitle.bold())

            Text("Paste an audio file or stream URL, then load it into the player.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var urlEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio URL")
                .font(.headline)

            TextField("Paste audio URL", text: $player.audioURLText)
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                #endif
                .autocorrectionDisabled()
                .focused($isURLFieldFocused)
                .onSubmit(playURL)
                .padding(14)
                .background(secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 8))

            Button(action: playURL) {
                Label(player.isLoading ? "Loading" : "Load and Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!player.canPlayCurrentURL || player.isLoading)
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlayback) {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!player.hasLoadedAudio || player.isLoading)

            Button(role: .destructive, action: player.stop) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!player.hasLoadedAudio)
        }
    }

    private var progressView: some View {
        VStack(spacing: 10) {
            Slider(
                value: $scrubberProgress,
                in: 0...1,
                onEditingChanged: { isEditing in
                    isScrubbing = isEditing
                    if !isEditing {
                        player.seek(to: scrubberProgress)
                    }
                }
            )
            .disabled(!player.hasDuration)

            HStack {
                Text(player.formattedTime(player.elapsedTime))
                Spacer()
                Text(player.hasDuration ? player.formattedTime(player.duration) : "Live")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(player.statusMessage, systemImage: player.isLoading ? "hourglass" : "waveform")
                .foregroundStyle(.secondary)

            if !player.currentURLText.isEmpty {
                Text(player.currentURLText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .font(.subheadline)
    }

    private func playURL() {
        isURLFieldFocused = false
        player.loadAndPlay()
    }

    private var groupedBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    private var secondaryGroupedBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

#Preview {
    ContentView()
}
