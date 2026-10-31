import Foundation
import Synchronization

/// A resolved host and port for the BSD dial path (NetService-resolved
/// announcements and manual connects).
public struct PresenceHostPort: Sendable, Equatable, Hashable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

// MARK: - Snapshot types

/// Where a peer stands in discovery (contract section 2: discovery state and
/// connection state are always tracked separately).
public enum PeerDiscoveryState: Sendable, Equatable {
    /// Known only from an inbound connection; never advertised.
    case inboundOnly
    case discovered
    case gone
}

/// Where a peer stands in its connection lifecycle.
public enum PeerConnectionState: Sendable, Equatable {
    /// No connection exists (or none any more).
    case idle
    case connecting
    case connected
    case unreachable
}

/// One peer as published to observers (Peers window, Settings status).
public struct PeerSnapshot: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let discovery: PeerDiscoveryState
    public let connection: PeerConnectionState
    public let playback: PresencePlaybackState?
    public let rttMs: Double?
    /// "caller" / "callee" while connected, for the peers view.
    public let role: String?

    public init(
        id: String,
        name: String,
        discovery: PeerDiscoveryState,
        connection: PeerConnectionState,
        playback: PresencePlaybackState?,
        rttMs: Double?,
        role: String?
    ) {
        self.id = id
        self.name = name
        self.discovery = discovery
        self.connection = connection
        self.playback = playback
        self.rttMs = rttMs
        self.role = role
    }
}

/// This Mac, as published to observers.
public struct SelfSnapshot: Sendable, Equatable {
    public let id: String
    public let name: String
    public let port: UInt16?
    public let running: Bool

    public init(id: String, name: String, port: UInt16?, running: Bool) {
        self.id = id
        self.name = name
        self.port = port
        self.running = running
    }
}

// MARK: - Directory broadcaster

/// Fan-out for the peer list. The Peers window and the Settings pane subscribe
/// independently, and two iterators of one `AsyncStream` would divide elements
/// between them, so each subscriber gets its own continuation seeded with the
/// current snapshot (the `unavailableSubscribers` pattern from `QueuePlayer`).
final class PeerDirectoryBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<[PeerSnapshot]>.Continuation]>([:])

    func subscribe() -> AsyncStream<[PeerSnapshot]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PeerSnapshot].self)
        let id = UUID()
        self.continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id: id)
        }
        return stream
    }

    func publish(_ peers: [PeerSnapshot]) {
        for continuation in self.continuations.withLock({ $0.values }) {
            continuation.yield(peers)
        }
    }

    private func remove(id: UUID) {
        _ = self.continuations.withLock { $0.removeValue(forKey: id) }
    }
}
