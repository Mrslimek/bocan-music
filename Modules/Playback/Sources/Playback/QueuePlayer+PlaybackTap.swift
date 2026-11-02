import AudioEngine
import Foundation
import Synchronization

// MARK: - PlaybackTapHub

/// The per-subscriber registry behind `QueuePlayer`'s playback tap fan-out.
///
/// `QueuePlayer.state` and `currentTrackChanges` are single-consumer
/// AsyncStreams already owned by `NowPlayingViewModel`, and two iterators of
/// one AsyncStream divide the elements between them, so non-UI observers (the
/// Presence subsystem, which maps this into the wire protocol's
/// `state_update`) subscribe here instead. The registry is a `Sendable` class
/// with one `Mutex` so the whole fan-out can live in an extension file without
/// moving stored properties out of the actor.
final class PlaybackTapHub: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<PlaybackTapSnapshot>.Continuation]>([:])

    func add(_ id: UUID, _ continuation: AsyncStream<PlaybackTapSnapshot>.Continuation) {
        self.subscribers.withLock { $0[id] = continuation }
    }

    func remove(_ id: UUID) {
        _ = self.subscribers.withLock { $0.removeValue(forKey: id) }
    }

    var subscriberCount: Int {
        self.subscribers.withLock { $0.count }
    }

    func emit(_ snapshot: PlaybackTapSnapshot) {
        for continuation in self.subscribers.withLock({ $0.values }) {
            continuation.yield(snapshot)
        }
    }
}

/// The per-subscriber registry behind `QueuePlayer`'s queue-snapshot fan-out
/// (same shape as `PlaybackTapHub`): every subscriber gets an independent
/// stream seeded with the current queue.
final class QueueSnapshotHub: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<QueueSnapshot>.Continuation]>([:])

    func add(_ id: UUID, _ continuation: AsyncStream<QueueSnapshot>.Continuation) {
        self.subscribers.withLock { $0[id] = continuation }
    }

    func remove(_ id: UUID) {
        _ = self.subscribers.withLock { $0.removeValue(forKey: id) }
    }

    var subscriberCount: Int {
        self.subscribers.withLock { $0.count }
    }

    func emit(_ snapshot: QueueSnapshot) {
        for continuation in self.subscribers.withLock({ $0.values }) {
            continuation.yield(snapshot)
        }
    }
}

// MARK: - QueuePlayer + Playback tap

extension QueuePlayer {
    /// Emits the current playback state with the current queue item: the
    /// current snapshot first, then again whenever the state changes. Each call
    /// returns an independent stream, and the subscriber is registered before
    /// the stream is returned, so nothing emitted after the call can be lost.
    public func playbackTapUpdates() async -> AsyncStream<PlaybackTapSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackTapSnapshot.self)
        let id = UUID()
        self.tapHub.add(id, continuation)
        let item = await self.queue.currentItem
        continuation.yield(await self.currentSnapshot(state: self.lastEmittedState, item: item))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.tapHub.remove(id) }
        }
        return stream
    }

    /// The single funnel for playback-state emission: the single-consumer
    /// `state` stream keeps serving `NowPlayingViewModel`, and every tap
    /// subscriber additionally receives the state with the current queue item
    /// attached. Awaited inline (not from a nested Task) so snapshots reach
    /// subscribers in emission order.
    func emitPlaybackState(_ state: PlaybackState) async {
        self.lastEmittedState = state
        self.stateContinuation?.yield(state)
        guard self.tapHub.subscriberCount > 0 else { return }
        let item = await self.queue.currentItem
        self.tapHub.emit(await self.currentSnapshot(state: state, item: item))
    }

    private func currentSnapshot(state: PlaybackState, item: QueueItem?) async -> PlaybackTapSnapshot {
        let shuffleState = await self.queue.shuffleState
        let repeatMode = await self.queue.repeatMode
        return PlaybackTapSnapshot(
            state: state,
            currentItem: item,
            shuffle: shuffleState != .off,
            repeat: repeatMode
        )
    }
}

// MARK: - Queue snapshot fan-out

extension QueuePlayer {
    /// Emits the current queue contents first, then again whenever the queue
    /// changes (any `QueueChange` — the consumer filters what it cares about,
    /// e.g. content-vs-mode changes). Each call returns an independent stream
    /// registered before the stream is returned.
    public func queueSnapshotUpdates() async -> AsyncStream<QueueSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: QueueSnapshot.self)
        let id = UUID()
        self.queueSnapshotHub.add(id, continuation)
        continuation.yield(QueueSnapshot(
            items: await self.queue.items,
            currentIndex: await self.queue.currentIndex
        ))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.queueSnapshotHub.remove(id) }
        }
        return stream
    }

    /// The single funnel for queue-change emission, called from the one
    /// `changes()` consumer (`subscribeToQueueChanges`).
    func emitQueueSnapshot() async {
        guard self.queueSnapshotHub.subscriberCount > 0 else { return }
        self.queueSnapshotHub.emit(QueueSnapshot(
            items: await self.queue.items,
            currentIndex: await self.queue.currentIndex
        ))
    }
}
