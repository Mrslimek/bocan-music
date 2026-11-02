import AudioEngine
import Foundation

/// A playback observation for non-UI consumers, delivered through the
/// per-subscriber fan-out on `QueuePlayer.playbackTapUpdates()`.
///
/// `QueuePlayer.state` and `currentTrackChanges` are single-consumer
/// `AsyncStream`s already owned by `NowPlayingViewModel`; lower modules that
/// need to observe playback (the Presence subsystem maps this into the wire
/// protocol's `state_update`) subscribe here instead, and every subscriber
/// receives an independent stream seeded with the current snapshot.
public struct PlaybackTapSnapshot: Sendable, Equatable {
    public let state: PlaybackState
    public let currentItem: QueueItem?
    /// Current queue modes (music-share playback-mode extension): reported so
    /// observers can reflect them truthfully. Defaults keep existing
    /// call sites compiling.
    public let shuffle: Bool
    public let `repeat`: RepeatMode

    public init(
        state: PlaybackState,
        currentItem: QueueItem?,
        shuffle: Bool = false,
        repeat: RepeatMode = .off
    ) {
        self.state = state
        self.currentItem = currentItem
        self.shuffle = shuffle
        self.repeat = `repeat`
    }
}

/// A point-in-time copy of the playback queue: the ordered items and the
/// current index. Delivered through `QueuePlayer.queueSnapshotUpdates()` so
/// non-UI consumers (the Presence subsystem broadcasts the queue as track
/// hashes, protocol section 9) can observe queue CONTENT changes without
/// competing for the single-consumer `changes()` stream.
public struct QueueSnapshot: Sendable, Equatable {
    public let items: [QueueItem]
    public let currentIndex: Int?

    public init(items: [QueueItem], currentIndex: Int?) {
        self.items = items
        self.currentIndex = currentIndex
    }
}
