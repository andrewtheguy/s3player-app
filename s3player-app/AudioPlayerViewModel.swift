//
//  AudioPlayerViewModel.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = "Loading audio..."
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var hasFinishedPlayback = false

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var pendingSeekSeconds: Double = 0

    var hasLoadedAudio: Bool {
        player != nil
    }

    var hasDuration: Bool {
        duration.isFinite && duration > 0
    }

    var progress: Double {
        guard hasDuration else { return 0 }
        return min(max(elapsedTime / duration, 0), 1)
    }

    func prepare(url: URL, resumeAtSeconds: Double = 0) {
        stop()
        guard configureAudioSession() else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        pendingSeekSeconds = max(0, resumeAtSeconds)
        elapsedTime = pendingSeekSeconds
        isLoading = true
        hasFinishedPlayback = false
        statusMessage = "Loading audio..."

        observe(item: item)
        addPeriodicTimeObserver(to: player)
    }

    func togglePlayback() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
            statusMessage = "Paused."
        } else {
            player.play()
            isPlaying = true
            statusMessage = "Playing."
        }
    }

    func stop() {
        if let player {
            player.pause()
            if let timeObserverToken {
                player.removeTimeObserver(timeObserverToken)
            }
        }

        player = nil
        timeObserverToken = nil
        itemStatusObservation = nil
        itemDurationObservation = nil
        removePlaybackEndObserver()

        isPlaying = false
        isLoading = false
        elapsedTime = 0
        duration = 0
        pendingSeekSeconds = 0
        hasFinishedPlayback = false
    }

    func seek(to progress: Double) {
        guard hasDuration, let player else { return }

        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = CMTime(seconds: duration * clampedProgress, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedTime = targetTime.seconds
            }
        }
    }

    func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "--:--" }

        let totalSeconds = Int(time.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private func configureAudioSession() -> Bool {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            statusMessage = "Audio session setup failed: \(error.localizedDescription)"
            return false
        }
        #else
        return true
        #endif
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(for: item)
            }
        }

        itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            }
        }

        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.statusMessage = "Finished."
                self?.hasFinishedPlayback = true
            }
        }
    }

    private func handleStatusChange(for item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isLoading = false
            duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            applyPendingSeekIfNeeded()
            statusMessage = isPlaying ? "Playing." : "Ready to play."
        case .failed:
            isLoading = false
            isPlaying = false
            statusMessage = item.error?.localizedDescription ?? "Unable to play this audio."
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func addPeriodicTimeObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)

        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.elapsedTime = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    private func applyPendingSeekIfNeeded() {
        guard pendingSeekSeconds > 0, let player else { return }
        let clamped = duration > 0 ? min(pendingSeekSeconds, max(0, duration - 0.5)) : pendingSeekSeconds
        pendingSeekSeconds = 0
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedTime = target.seconds
            }
        }
    }

    private func removePlaybackEndObserver() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }

        playbackEndObserver = nil
    }
}
