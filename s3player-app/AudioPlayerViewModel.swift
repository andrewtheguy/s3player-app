//
//  AudioPlayerViewModel.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage = "Loading audio..."
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var hasFinishedPlayback = false
    @Published private(set) var playbackUnsupported = false

    private var player: AVPlayer?
    private var timeObserverToken: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var pendingSeekSeconds: Double = 0
    private var nowPlayingTitle: String?
    private var nowPlayingArtist: String?
    private var didConfigureRemoteCommands = false
    private var didReachReadyToPlay = false
    private var remoteCommandTokens: [(MPRemoteCommand, Any)] = []

    /// Gate consulted by lock-screen / Control Center "play" or
    /// toggle-while-paused commands. Remote commands bypass the in-app
    /// `PlaybackController.togglePlayback()` session check, so without this
    /// gate a stale lock-screen Play button can resume audio while the session
    /// is `.displaced`, producing an inconsistent UI.
    var canStartRemotePlayback: () -> Bool = { true }

    deinit {
        // MPRemoteCommandCenter retains every closure added via addTarget(handler:).
        // Without this cleanup, each PlayerView instance leaks 6 closures into the
        // shared command center for the lifetime of the app.
        for (command, token) in remoteCommandTokens {
            command.removeTarget(token)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

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

    func prepare(
        url: URL,
        httpHeaders: [String: String] = [:],
        resumeAtSeconds: Double = 0,
        title: String,
        artist: String
    ) {
        stop()
        guard configureAudioSession() else { return }

        // AVURLAssetHTTPHeaderFieldsKey lets AVPlayer attach headers (e.g. a bearer
        // token) for remote URLs. Local file playback passes [:] — the parameter
        // is kept so callers don't churn if a future code path needs streaming.
        var assetOptions: [String: Any] = [:]
        if !httpHeaders.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders
        }
        let asset = AVURLAsset(url: url, options: assetOptions.isEmpty ? nil : assetOptions)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        pendingSeekSeconds = max(0, resumeAtSeconds)
        elapsedTime = pendingSeekSeconds
        nowPlayingTitle = title
        nowPlayingArtist = artist
        isLoading = true
        hasFinishedPlayback = false
        statusMessage = "Loading audio..."

        playbackUnsupported = false
        didReachReadyToPlay = false

        observe(item: item)
        addPeriodicTimeObserver(to: player)
        configureRemoteCommandsIfNeeded()
        configureInterruptionObserverIfNeeded()
        updateNowPlayingInfo()
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
        updateNowPlayingInfo()
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
        wasPlayingBeforeInterruption = false
        hasFinishedPlayback = false
        playbackUnsupported = false
        didReachReadyToPlay = false
        nowPlayingTitle = nil
        nowPlayingArtist = nil
        clearNowPlayingInfo()
    }

    func seek(to progress: Double) {
        guard hasDuration, let player else { return }

        let clampedProgress = min(max(progress, 0), 1)
        let targetTime = CMTime(seconds: duration * clampedProgress, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedTime = targetTime.seconds
                self?.updateNowPlayingInfo()
            }
        }
    }

    func skip(by seconds: Double) {
        guard hasDuration, let player else { return }
        let target = max(0, min(duration - 0.5, elapsedTime + seconds))
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedTime = targetTime.seconds
                self?.updateNowPlayingInfo()
            }
        }
    }

    // Update the resume target whether the asset is already ready (seek directly)
    // or still loading (defer via pendingSeekSeconds, applied on .readyToPlay).
    func setResumePosition(toSeconds seconds: Double) {
        let target = max(0, seconds)
        if let player, hasDuration {
            let clamped = min(target, max(0, duration - 0.5))
            let time = CMTime(seconds: clamped, preferredTimescale: 600)
            pendingSeekSeconds = 0
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.elapsedTime = time.seconds
                    self?.updateNowPlayingInfo()
                }
            }
        } else {
            pendingSeekSeconds = target
            elapsedTime = target
            updateNowPlayingInfo()
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
                guard let self else { return }
                self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                self.refreshPlaybackSupported()
                self.updateNowPlayingInfo()
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
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func handleStatusChange(for item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isLoading = false
            duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
            didReachReadyToPlay = true
            refreshPlaybackSupported()
            applyPendingSeekIfNeeded()
            if !playbackUnsupported {
                statusMessage = isPlaying ? "Playing." : "Ready to play."
            }
            updateNowPlayingInfo()
        case .failed:
            isLoading = false
            isPlaying = false
            statusMessage = item.error?.localizedDescription ?? "Unable to play this audio."
            updateNowPlayingInfo()
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

    // Once an item reaches .readyToPlay, a missing/Infinite/zero duration means
    // we cannot track progress or completion. Pause and surface a flag so the
    // controller can refuse to write progress and the view can explain why.
    private func refreshPlaybackSupported() {
        guard didReachReadyToPlay else { return }
        let supported = hasDuration
        if supported {
            if playbackUnsupported {
                playbackUnsupported = false
            }
            return
        }
        if !playbackUnsupported {
            playbackUnsupported = true
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
        }
        statusMessage = "Cannot play: unknown duration."
    }

    private func applyPendingSeekIfNeeded() {
        guard pendingSeekSeconds > 0, let player else { return }
        let clamped = duration > 0 ? min(pendingSeekSeconds, max(0, duration - 0.5)) : pendingSeekSeconds
        pendingSeekSeconds = 0
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedTime = target.seconds
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func removePlaybackEndObserver() {
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }

        playbackEndObserver = nil
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()

        // MPRemoteCommandCenter invokes these handlers on an arbitrary queue, so every
        // touch of MainActor-isolated state must hop via Task { @MainActor in ... }.
        // Tokens returned by addTarget(handler:) are captured so deinit can remove them.

        let playToken = center.playCommand.addTarget { [weak self] _ in
            self?.handleRemotePlay() ?? .commandFailed
        }
        remoteCommandTokens.append((center.playCommand, playToken))

        let pauseToken = center.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemotePause() ?? .commandFailed
        }
        remoteCommandTokens.append((center.pauseCommand, pauseToken))

        let toggleToken = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying {
                    self.togglePlayback()
                } else if self.canStartRemotePlayback() {
                    self.togglePlayback()
                }
            }
            return .success
        }
        remoteCommandTokens.append((center.togglePlayPauseCommand, toggleToken))

        center.skipBackwardCommand.preferredIntervals = [15]
        let skipBackToken = center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: -15) }
            return .success
        }
        remoteCommandTokens.append((center.skipBackwardCommand, skipBackToken))

        center.skipForwardCommand.preferredIntervals = [30]
        let skipForwardToken = center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: 30) }
            return .success
        }
        remoteCommandTokens.append((center.skipForwardCommand, skipForwardToken))

        // Bluetooth remotes (AVRCP) send next/previous track rather than
        // skip-interval. Map them to the same +30 / -15 actions so headset
        // and car controls behave like the lock-screen skip buttons.
        let nextTrackToken = center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: 30) }
            return .success
        }
        remoteCommandTokens.append((center.nextTrackCommand, nextTrackToken))

        let previousTrackToken = center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.skip(by: -15) }
            return .success
        }
        remoteCommandTokens.append((center.previousTrackCommand, previousTrackToken))

        let positionToken = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard
                let self,
                let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            let positionTime = event.positionTime
            Task { @MainActor [weak self] in
                guard let self, let player = self.player, self.hasDuration else { return }
                let target = CMTime(seconds: positionTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    Task { @MainActor [weak self] in
                        self?.elapsedTime = target.seconds
                        self?.updateNowPlayingInfo()
                    }
                }
            }
            return .success
        }
        remoteCommandTokens.append((center.changePlaybackPositionCommand, positionToken))
    }

    // Subscribe to audio-session interruptions (phone calls, Siri, other apps
    // grabbing the session — common in the car over Bluetooth/CarPlay). Without
    // this, an interruption pauses our AVPlayer at the OS level while `isPlaying`
    // stays true (UI stuck "playing") and playback never resumes when the call
    // ends. Registered once; the session notification is global, not per-item.
    private func configureInterruptionObserverIfNeeded() {
        #if os(iOS)
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            // Pull the Sendable values out of the (non-Sendable) notification
            // before hopping to the MainActor.
            guard
                let info = notification.userInfo,
                let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, options: options)
            }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(
        type: AVAudioSession.InterruptionType,
        options: AVAudioSession.InterruptionOptions
    ) {
        switch type {
        case .began:
            // The system has already paused us. Sync UI state and remember we
            // were playing so we can resume once the interruption ends.
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                isPlaying = false
                statusMessage = "Paused."
                updateNowPlayingInfo()
            }
        case .ended:
            guard wasPlayingBeforeInterruption else { return }
            wasPlayingBeforeInterruption = false
            // Only resume when the system grants it (.shouldResume) and the
            // app's own session gate still allows playback (not displaced).
            guard options.contains(.shouldResume), canStartRemotePlayback() else { return }
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    private func resumeAfterInterruption() {
        guard let player else { return }
        // The session is deactivated during an interruption; reactivate it
        // before resuming or play() silently no-ops.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            statusMessage = "Could not resume audio: \(error.localizedDescription)"
            return
        }
        player.play()
        isPlaying = true
        statusMessage = "Playing."
        updateNowPlayingInfo()
    }
    #endif

    nonisolated private func handleRemotePlay() -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, !self.isPlaying else { return }
            guard self.canStartRemotePlayback() else { return }
            player.play()
            self.isPlaying = true
            self.statusMessage = "Playing."
            self.updateNowPlayingInfo()
        }
        return .success
    }

    nonisolated private func handleRemotePause() -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak self] in
            guard let self, let player = self.player, self.isPlaying else { return }
            player.pause()
            self.isPlaying = false
            self.statusMessage = "Paused."
            self.updateNowPlayingInfo()
        }
        return .success
    }

    /// Toggle the lock-screen / Control Center "play" affordances. Pause stays
    /// enabled unconditionally so the user can always stop audio. Pair this
    /// with `canStartRemotePlayback` so a tap that slips through (button still
    /// rendered between the disable and the next refresh) is also rejected.
    func setRemotePlayCommandEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
    }

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        if let nowPlayingTitle {
            info[MPMediaItemPropertyTitle] = nowPlayingTitle
        }
        if let nowPlayingArtist {
            info[MPMediaItemPropertyArtist] = nowPlayingArtist
        }
        if hasDuration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
