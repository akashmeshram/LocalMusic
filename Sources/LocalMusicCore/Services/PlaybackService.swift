import Foundation
import AVFoundation
import MediaPlayer
import Observation

public enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one
}

/// Local playback over `AVPlayer`, plus system media-key and Now Playing integration.
@MainActor
@Observable
public final class PlaybackService {
    public private(set) var currentTrack: TrackRecord?
    public private(set) var isPlaying = false
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var queue: [TrackRecord] = []
    public private(set) var queueIndex: Int?
    public var isShuffling = false
    public var repeatMode: RepeatMode = .off
    public var volume: Float {
        didSet { player.volume = volume }
    }

    /// Called when a track has played to the end (for play counts).
    public var onTrackFinished: (@MainActor (TrackRecord) -> Void)?
    /// Called periodically with the current position so it can be remembered.
    public var onPositionChanged: (@MainActor (TrackRecord, TimeInterval) -> Void)?
    /// Provides artwork bytes for the Now Playing widget.
    public var artworkProvider: (@MainActor (TrackRecord) -> Data?)?

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var shuffledOrder: [Int] = []
    private var isSeeking = false
    private var lastReportedPosition: TimeInterval = 0

    public init(initialVolume: Float = 0.8) {
        volume = initialVolume
        player.volume = initialVolume
        player.actionAtItemEnd = .pause
        installTimeObserver()
        installRemoteCommands()
    }

    // MARK: Queue control

    public func play(_ tracks: [TrackRecord], startingAt index: Int = 0) {
        guard !tracks.isEmpty, tracks.indices.contains(index) else { return }
        queue = tracks
        rebuildShuffleOrder(startingWith: index)
        load(index: index, autoplay: true)
    }

    public func play(_ track: TrackRecord) { play([track]) }

    public func playNext(_ track: TrackRecord) {
        if queue.isEmpty { play(track); return }
        let insertAt = (queueIndex ?? -1) + 1
        queue.insert(track, at: insertAt)
        rebuildShuffleOrder(startingWith: queueIndex ?? 0)
    }

    public func enqueue(_ track: TrackRecord) {
        if queue.isEmpty { play(track); return }
        queue.append(track)
        rebuildShuffleOrder(startingWith: queueIndex ?? 0)
    }

    public func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index), index != queueIndex else { return }
        queue.remove(at: index)
        if let qi = queueIndex, index < qi { queueIndex = qi - 1 }
        rebuildShuffleOrder(startingWith: queueIndex ?? 0)
    }

    public func clearQueue() {
        stop()
        queue = []
        queueIndex = nil
        shuffledOrder = []
    }

    // MARK: Transport

    public func togglePlayPause() {
        if currentTrack == nil, !queue.isEmpty { load(index: queueIndex ?? 0, autoplay: true); return }
        isPlaying ? pause() : resume()
    }

    public func resume() {
        guard currentTrack != nil else { return }
        player.play()
        isPlaying = true
        updateNowPlayingPlaybackState()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        updateNowPlayingPlaybackState()
    }

    public func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTrack = nil
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    public func next() {
        guard let nextIndex = nextIndex(after: queueIndex) else {
            if repeatMode == .all, let first = playbackOrder.first { load(index: first, autoplay: true) } else { stop() }
            return
        }
        load(index: nextIndex, autoplay: true)
    }

    public func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let prev = previousIndex(before: queueIndex) else { seek(to: 0); return }
        load(index: prev, autoplay: true)
    }

    public func seek(to seconds: TimeInterval) {
        guard currentTrack != nil else { return }
        let clamped = max(0, min(seconds, duration))
        isSeeking = true
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            // AVPlayer calls back on its own queue; hop explicitly instead of trapping on isolation.
            Task { @MainActor in
                self?.isSeeking = false
                self?.updateNowPlayingElapsed()
            }
        }
    }

    public func toggleShuffle() {
        isShuffling.toggle()
        rebuildShuffleOrder(startingWith: queueIndex ?? 0)
    }

    public func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
    }

    // MARK: Loading

    private func load(index: Int, autoplay: Bool, startAt: TimeInterval? = nil) {
        guard queue.indices.contains(index) else { return }
        let track = queue[index]
        queueIndex = index
        currentTrack = track
        currentTime = startAt ?? 0
        duration = track.duration
        lastReportedPosition = 0

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil

        let item = AVPlayerItem(url: track.fileURL)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTrackEnded() }
        }
        statusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            let failure = item.status == .failed ? (item.error?.localizedDescription ?? "unknown error") : nil
            let loadedDuration = item.status == .readyToPlay ? CMTimeGetSeconds(item.duration) : nil
            Task { @MainActor in
                guard let self else { return }
                if let failure {
                    Log.error("playback failed for \(track.fileURL.lastPathComponent): \(failure)", .playback)
                    self.isPlaying = false
                } else if let loadedDuration, loadedDuration.isFinite, loadedDuration > 0 {
                    self.duration = loadedDuration
                    self.updateNowPlayingInfo()
                }
            }
        }
        player.replaceCurrentItem(with: item)
        if let startAt, startAt > 0 { player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600)) }
        updateNowPlayingInfo()
        if autoplay { resume() } else { pause() }
        Log.info("now playing: \(track.title)", .playback)
    }

    private func handleTrackEnded() {
        guard let finished = currentTrack else { return }
        onTrackFinished?(finished)
        switch repeatMode {
        case .one:
            seek(to: 0); resume()
        case .all, .off:
            next()
        }
    }

    // MARK: Ordering

    private var playbackOrder: [Int] { isShuffling ? shuffledOrder : Array(queue.indices) }

    private func rebuildShuffleOrder(startingWith index: Int) {
        var rest = Array(queue.indices).filter { $0 != index }
        rest.shuffle()
        shuffledOrder = queue.indices.contains(index) ? [index] + rest : rest
    }

    private func nextIndex(after current: Int?) -> Int? {
        let order = playbackOrder
        guard let current, let pos = order.firstIndex(of: current), pos + 1 < order.count else { return nil }
        return order[pos + 1]
    }

    private func previousIndex(before current: Int?) -> Int? {
        let order = playbackOrder
        guard let current, let pos = order.firstIndex(of: current), pos > 0 else { return nil }
        return order[pos - 1]
    }

    // MARK: Time observation

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isSeeking else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if let track = self.currentTrack, abs(seconds - self.lastReportedPosition) >= 5 {
                    self.lastReportedPosition = seconds
                    self.onPositionChanged?(track, seconds)
                }
            }
        }
    }

    // MARK: System integration

    /// Media keys / Now Playing commands. MediaPlayer does not promise a thread, so every handler is
    /// `@Sendable` and hops to the main actor rather than asserting it.
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handler(_ action: @escaping @MainActor (PlaybackService) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
        }
        center.playCommand.addTarget(handler: handler { $0.resume() })
        center.pauseCommand.addTarget(handler: handler { $0.pause() })
        center.togglePlayPauseCommand.addTarget(handler: handler { $0.togglePlayPause() })
        center.nextTrackCommand.addTarget(handler: handler { $0.next() })
        center.previousTrackCommand.addTarget(handler: handler { $0.previous() })
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let data = artworkProvider?(track), let image = NSImage(data: data) {
            // The request handler runs on MediaPlayer's thread; NSImage is thread-safe for drawing.
            nonisolated(unsafe) let art = image
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in art }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateNowPlayingPlaybackState()
    }

    private func updateNowPlayingPlaybackState() {
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : (currentTrack == nil ? .stopped : .paused)
        updateNowPlayingElapsed()
    }

    private func updateNowPlayingElapsed() {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

import AppKit
