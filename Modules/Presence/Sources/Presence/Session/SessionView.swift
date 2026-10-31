import Foundation

/// The shared session as the UI should see it (contract section 8), owned
/// entirely by `PresenceEngine` and published on `sessionUpdates()`.
///
/// This is a DIFFERENT axis from connection state: a device can disconnect
/// while the session still exists. Losing connectivity marks the remote stint
/// `.unreachable` (then `.gone` after expiry or goodbye) but never silently
/// switches the session back to local playback - only self actually starting
/// a local playing stint does that.
public struct SessionView: Sendable, Equatable {
    /// How the local device relates to the active stint.
    public enum Source: Sendable, Equatable {
        /// This Mac is the active device (or no remote stint exists).
        case local
        /// A peer owns the active stint. The session survives disconnects.
        case remote(RemoteStint)
        /// A handoff from `peer` is being started locally (track resolved,
        /// local playback starting). Cleared when self's playing broadcast
        /// lands or the handoff fails.
        case takeoverInFlight(RemoteTakeover)
    }

    /// How reachable the stint's owner currently is.
    public enum Reachability: Sendable, Equatable {
        case connected
        case unreachable
        case gone
    }

    /// The remote side of the active stint.
    public struct RemoteStint: Sendable, Equatable {
        public let peerID: String
        public let peerName: String
        public let reachability: Reachability
        /// The last state the peer announced for this stint. Authoritative:
        /// views may dead-reckon position for display but must not write back.
        public let lastKnown: LastKnown

        public init(
            peerID: String,
            peerName: String,
            reachability: Reachability,
            lastKnown: LastKnown
        ) {
            self.peerID = peerID
            self.peerName = peerName
            self.reachability = reachability
            self.lastKnown = lastKnown
        }
    }

    /// The takeover being started locally.
    public struct RemoteTakeover: Sendable, Equatable {
        public let peerID: String
        public let peerName: String
        public let trackHash: String
        public let positionSec: Double

        public init(peerID: String, peerName: String, trackHash: String, positionSec: Double) {
            self.peerID = peerID
            self.peerName = peerName
            self.trackHash = trackHash
            self.positionSec = positionSec
        }
    }

    /// The last announced state of a remote stint.
    public struct LastKnown: Sendable, Equatable {
        public let trackHash: String
        public let trackTitle: String
        public let positionSec: Double
        public let playbackId: String
        public let status: PresenceStatus
        /// Unix ms of the moment the engine recorded this state.
        public let updatedAtMs: Double

        public init(
            trackHash: String,
            trackTitle: String,
            positionSec: Double,
            playbackId: String,
            status: PresenceStatus,
            updatedAtMs: Double
        ) {
            self.trackHash = trackHash
            self.trackTitle = trackTitle
            self.positionSec = positionSec
            self.playbackId = playbackId
            self.status = status
            self.updatedAtMs = updatedAtMs
        }
    }

    /// A `session_conflict` episode: the device names involved and when it
    /// was detected. Never auto-resolved by the protocol; cleared when the
    /// overlap ends.
    public struct Conflict: Sendable, Equatable {
        public let deviceNames: [String]
        public let detectedAtMs: Double

        public init(deviceNames: [String], detectedAtMs: Double) {
            self.deviceNames = deviceNames
            self.detectedAtMs = detectedAtMs
        }
    }

    public var source: Source
    public var conflict: Conflict?
    /// The track hash of the last failed handoff resolution
    /// (`library_unsynced`); nil once a later handoff or stint change happens.
    public var lastUnsynced: String?

    public init(source: Source, conflict: Conflict? = nil, lastUnsynced: String? = nil) {
        self.source = source
        self.conflict = conflict
        self.lastUnsynced = lastUnsynced
    }

    /// True when the active stint belongs to a peer that is still connected.
    public var isRemoteConnected: Bool {
        if case let .remote(stint) = self.source, stint.reachability == .connected {
            return true
        }
        return false
    }

    /// True when any remote stint exists (connected or last-known).
    public var isRemote: Bool {
        if case .remote = self.source { return true }
        return false
    }
}
