import AudioEngine
import Foundation
import Playback

/// Maps Bòcan's playback into the protocol's playback state (contract section
/// 6): `QueueItem.title` becomes `track`, `artistName` becomes the `artist`
/// extension field, `PlaybackState` maps to playing/paused/stopped, and the
/// polled `currentTime` becomes `positionSec`.
///
/// The tap is a dumb observer: it reports every change to the engine, which
/// owns the seq counter and the broadcast policy (discrete changes broadcast
/// immediately; position refreshes stay throttled so the wire is not flooded).
public actor PlaybackTap {
    /// Seconds between position polls while playing (the NowPlayingViewModel
    /// cadence precedent).
    static let positionPollInterval: TimeInterval = 0.5

    private let snapshots: @Sendable () async -> AsyncStream<PlaybackTapSnapshot>
    private let currentTime: @Sendable () async -> TimeInterval
    private let onChange: @Sendable (PresencePlaybackState) async -> Void
    /// Resolves the shared-session `trackHash` for a track (contract section
    /// 8). Called once per track change, never per position tick; nil means
    /// the hash could not be determined (the peer stays non-session-capable).
    private let trackHashProvider: @Sendable (Int64) async -> String?

    private var observeTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var latest: PlaybackTapSnapshot?
    private var lastHashedTrackID: Int64?
    private var lastTrackHash: String?

    /// - Parameters:
    ///   - player: the queue player to observe and poll for position.
    ///   - trackHashProvider: the shared-session hash resolver (contract
    ///     section 8), invoked once per track change.
    ///   - onChange: called on every mapped state change (status, track, or
    ///     polled position); the engine owns seq and broadcast policy.
    public init(
        player: QueuePlayer,
        trackHashProvider: @escaping @Sendable (Int64) async -> String? = { _ in nil },
        onChange: @escaping @Sendable (PresencePlaybackState) async -> Void
    ) {
        self.snapshots = { await player.playbackTapUpdates() }
        self.currentTime = { await player.currentTime }
        self.onChange = onChange
        self.trackHashProvider = trackHashProvider
    }

    /// Test seam: any snapshot source and clock.
    init(
        snapshots: @escaping @Sendable () async -> AsyncStream<PlaybackTapSnapshot>,
        currentTime: @escaping @Sendable () async -> TimeInterval,
        trackHashProvider: @escaping @Sendable (Int64) async -> String? = { _ in nil },
        onChange: @escaping @Sendable (PresencePlaybackState) async -> Void
    ) {
        self.snapshots = snapshots
        self.currentTime = currentTime
        self.onChange = onChange
        self.trackHashProvider = trackHashProvider
    }

    /// Begins observing the playback fan-out. Idempotent.
    public func start() {
        guard self.observeTask == nil else { return }
        let snapshots = self.snapshots
        self.observeTask = Task {
            for await snapshot in await snapshots() {
                await self.apply(snapshot)
            }
        }
    }

    /// Cancels the observation and the position poll. Idempotent.
    public func stop() {
        self.observeTask?.cancel()
        self.observeTask = nil
        self.positionTask?.cancel()
        self.positionTask = nil
    }

    private func apply(_ snapshot: PlaybackTapSnapshot) async {
        self.latest = snapshot
        // The hash is a property of the track, not the moment: resolve it once
        // per track change (lazy index lookup, cached here and downstream).
        let trackID = snapshot.currentItem?.trackID
        if trackID != self.lastHashedTrackID {
            self.lastHashedTrackID = trackID
            if let trackID {
                self.lastTrackHash = await self.trackHashProvider(trackID)
            } else {
                self.lastTrackHash = nil
            }
        }
        if snapshot.state == .playing {
            self.startPositionPoll()
        } else {
            self.positionTask?.cancel()
            self.positionTask = nil
            await self.emitPosition()
        }
    }

    private func startPositionPoll() {
        guard self.positionTask == nil else { return }
        self.positionTask = Task {
            while !Task.isCancelled {
                await self.emitPosition()
                try? await Task.sleep(nanoseconds: UInt64(Self.positionPollInterval * 1_000_000_000))
            }
        }
    }

    private func emitPosition() async {
        guard let latest = self.latest else { return }
        let position = await self.currentTime()
        await self.onChange(
            Self.mapped(
                state: latest.state,
                item: latest.currentItem,
                position: position,
                trackHash: self.lastTrackHash,
                shuffle: latest.shuffle,
                repeatMode: latest.repeat
            )
        )
    }

    static func mapped(
        state: PlaybackState,
        item: QueueItem?,
        position: TimeInterval,
        trackHash: String?,
        shuffle: Bool? = nil,
        repeatMode: RepeatMode? = nil
    ) -> PresencePlaybackState {
        let status: PresenceStatus = switch state {
        case .playing:
            .playing

        case .paused:
            .paused

        default:
            .stopped
        }
        // The engine assigns the seq and the playback stint id. The queue
        // modes are the playback-mode extension (contract section 6).
        return PresencePlaybackState(
            track: item?.title ?? "",
            status: status,
            positionSec: position,
            seq: 0,
            artist: item?.artistName,
            trackHash: trackHash,
            shuffle: shuffle,
            repeat: repeatMode.flatMap { PresenceRepeatMode(rawValue: $0.rawValue) }
        )
    }
}
