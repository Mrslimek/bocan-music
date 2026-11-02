import Foundation
import Playback

// MARK: - Queue sharing sender (contract section 9)

/// What was last queued for send / last sent: the ordered hashes plus the
/// current index within them. Used to suppress no-op broadcasts.
struct QueueFingerprint: Equatable {
    let hashes: [String]
    let current: Int?
}

/// Bòcan's sender side of the queue-sharing extension: broadcast the local
/// playback queue as ordered track hashes so a taker can reconstruct it.
/// Receiving logic is not implemented this round — inbound `queue` messages
/// are only validated and logged per the tolerant-receiver rules.
extension PresenceEngine {
    /// Full queue up to this many entries; beyond it, a window of this size
    /// centered on the current entry. The 1000-entry wire cap is never
    /// approached (200 << 1000).
    static let queueWindowLimit = 200

    /// Hex charset of a lowercase SHA-256 hex string (64 chars), used to
    /// validate inbound `queue` payloads (contract section 9).
    private static func isHex(_ hash: String) -> Bool {
        let charset = Set("0123456789abcdef")
        return hash.count == 64 && hash.allSatisfy { charset.contains($0) }
    }

    // MARK: Lifecycle

    /// Observes the player's queue snapshot fan-out. Idempotent; called from
    /// `start()` alongside the playback tap.
    func startQueueObservation(player: QueuePlayer) {
        guard self.queueObserveTask == nil else { return }
        self.queueObserveTask = Task { [weak self] in
            let updates = await player.queueSnapshotUpdates()
            for await snapshot in updates {
                guard let self, await self.isRunning else { return }
                await self.handleQueueSnapshot(snapshot)
            }
        }
    }

    func stopQueueObservation() {
        self.queueObserveTask?.cancel()
        self.queueObserveTask = nil
        self.queueSendTask?.cancel()
        self.queueSendTask = nil
    }

    // MARK: Outgoing

    /// A queue-content change: resolve hashes (cached per trackID), skip when
    /// nothing observable changed since the last send, and schedule a
    /// debounced broadcast. Position ticks and play/pause never produce a
    /// `QueueChange`, so they cannot trigger this path.
    func handleQueueSnapshot(_ snapshot: QueueSnapshot) async {
        let message = await self.queueMessage(from: snapshot)
        let fingerprint = QueueFingerprint(hashes: message.hashes ?? [], current: message.current)
        if fingerprint == self.lastQueueFingerprint {
            return
        }
        self.pendingQueueFingerprint = fingerprint
        guard self.queueSendTask == nil else { return } // a fire is already scheduled; it reads the latest
        let debounce = self.config.queueDebounce
        self.queueSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.flushQueueBroadcast()
        }
    }

    /// Sends the latest queued snapshot and clears the pending fingerprint.
    func flushQueueBroadcast() async {
        self.queueSendTask = nil
        guard let fingerprint = self.pendingQueueFingerprint else { return }
        self.lastQueueFingerprint = fingerprint
        self.pendingQueueFingerprint = nil
        let message = PresenceQueueMessage(current: fingerprint.current, hashes: fingerprint.hashes)
        let connected = Array(self.connections.values)
        guard !connected.isEmpty else { return }
        for connection in connected {
            await connection.sendQueue(message)
        }
        self.log.debug("presence.queue_sent", [
            "to": String(connected.count),
            "entries": String(message.hashes?.count ?? 0),
            "current": message.current.map(String.init) ?? "-",
        ])
    }

    /// The current queue message, built from the player's queue with the
    /// session hash provider (cached per trackID). Unresolvable entries are
    /// dropped; the current index is the resolved current item's position in
    /// the emitted array. nil when the current item itself has no hash
    /// (nothing playing is still a valid send with current == nil).
    func queueMessage(from snapshot: QueueSnapshot) async -> PresenceQueueMessage {
        var hashes: [String] = []
        hashes.reserveCapacity(snapshot.items.count)
        var current: Int?
        for (index, item) in snapshot.items.enumerated() {
            let hash = await self.cachedHash(for: item.trackID)
            guard let hash else {
                if index == snapshot.currentIndex { current = nil }
                continue
            }
            if index == snapshot.currentIndex {
                current = hashes.count
            }
            hashes.append(hash)
        }
        // Window policy (contract section 9): full queue at <= 200 entries,
        // otherwise a 200-entry window centered on the current entry.
        if hashes.count > Self.queueWindowLimit, let current {
            let start = max(0, min(current - Self.queueWindowLimit / 2, hashes.count - Self.queueWindowLimit))
            let end = start + Self.queueWindowLimit
            let offset = current - start
            return PresenceQueueMessage(current: offset, hashes: Array(hashes[start..<end]))
        }
        if hashes.count > Self.queueWindowLimit {
            return PresenceQueueMessage(current: nil, hashes: Array(hashes.prefix(Self.queueWindowLimit)))
        }
        return PresenceQueueMessage(current: current, hashes: hashes)
    }

    /// The current queue message built from the player's live queue (used for
    /// the post-handshake snapshot). Tests inject a fabricated source via
    /// ``setQueueSnapshotForTesting``.
    func queueMessageForSending() async -> PresenceQueueMessage? {
        guard let source = self.queueSnapshotSource, let snapshot = await source() else { return nil }
        return await self.queueMessage(from: snapshot)
    }

    /// Per-trackID hash cache over the lazy provider: queue sends after the
    /// first are instant, and an unresolvable track (nil) is remembered so it
    /// is not re-hashed on every send.
    private func cachedHash(for trackID: Int64) async -> String? {
        if let cached = self.queueHashCache[trackID] {
            return cached
        }
        let hash = await self.trackHashProvider(trackID)
        self.queueHashCache[trackID] = hash
        return hash
    }

    // MARK: Inbound (validate + log only this round)

    /// Receiver rules for `queue` (contract section 9): non-array hashes (nil
    /// from the lenient codec), non-hex entries, or an out-of-bounds current
    /// index are `message_malformed`, ignored, never disconnecting. A valid
    /// snapshot is logged; receiving logic arrives with the takeover work.
    func applyInboundQueue(_ message: PresenceQueueMessage, owner: String) {
        let peerName = self.peers[owner]?.name ?? owner
        guard let hashes = message.hashes else {
            self.log.debug("presence.message_malformed", [
                "peer": owner,
                "type": "queue",
                "reason": "hashes is not a string array",
            ])
            return
        }
        guard hashes.allSatisfy(Self.isHex) else {
            self.log.debug("presence.message_malformed", [
                "peer": owner,
                "type": "queue",
                "reason": "non-hex hash entry",
            ])
            return
        }
        let current = message.current.flatMap { $0 < 0 ? nil : $0 }
        if let current, current >= hashes.count {
            self.log.debug("presence.message_malformed", [
                "peer": owner,
                "type": "queue",
                "reason": "current index out of bounds",
            ])
            return
        }
        self.log.debug("presence.queue_recv", [
            "peer": owner,
            "name": peerName,
            "entries": String(hashes.count),
            "current": current.map(String.init) ?? "-",
        ])
    }

    // MARK: Test seams

    /// Injects a fabricated queue source (or nil to disable queue sending) so
    /// protocol tests can drive the sender path without a real QueuePlayer.
    func setQueueSnapshotForTesting(_ source: (@Sendable () async -> QueueSnapshot?)?) {
        self.queueSnapshotSource = source
    }

    /// Feeds a snapshot through the sender path (fingerprint + debounce) as
    /// the queue observation would.
    func handleQueueSnapshotForTesting(_ snapshot: QueueSnapshot) async {
        await self.handleQueueSnapshot(snapshot)
    }

    /// The last fingerprint the engine actually sent, for suppression tests.
    func lastQueueFingerprintForTesting() -> QueueFingerprint? {
        self.lastQueueFingerprint
    }
}
