import Foundation
import Synchronization

// MARK: - Engine-owned session view (contract section 8)

/// The session-view state machine lives here. Every transition goes through
/// `updateSession`, which mutates the holder and publishes to subscribers.
/// Connection state and session state are different axes: a disconnect marks
/// the stint `.unreachable`/`.gone` but never falls back to `.local` - only
/// self actually starting a local playing stint does that.
extension PresenceEngine {
    // MARK: Public surface

    /// Per-subscriber stream of the session view (main player surface).
    public func sessionUpdates() -> AsyncStream<SessionView> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionView.self)
        let id = UUID()
        self.sessionContinuations.withLock { $0[id] = continuation }
        continuation.yield(self.session)
        let continuations = Mutex(self.sessionContinuations.withLock { $0 })
        continuation.onTermination = { _ in
            continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    /// Marks a handoff as being started locally: the track resolved against
    /// the local index and local playback is about to begin. Cleared when
    /// self's playing broadcast lands (`applyOwnState`) or by
    /// ``cancelTakeover()`` on failure.
    public func beginTakeover(peerID: String, peerName: String, trackHash: String, positionSec: Double) {
        self.updateSession { view in
            view.source = .takeoverInFlight(.init(
                peerID: peerID,
                peerName: peerName,
                trackHash: trackHash,
                positionSec: positionSec
            ))
            view.lastUnsynced = nil
        }
        self.log.debug("presence.session.takeover_in_flight", [
            "peer": peerID,
            "name": peerName,
            "pos": String(format: "%.1f", positionSec),
        ])
    }

    /// A handoff failed locally (load/play error): restore the view as it was
    /// before the attempt. Per the contract nothing was sent on the wire for
    /// a `library_unsynced` failure, so the remote stint stays untouched.
    public func cancelTakeover() {
        self.updateSession { view in
            if case .takeoverInFlight = view.source, let previous = self.takeoverPrevious {
                view = previous
            }
        }
        self.takeoverPrevious = nil
    }

    /// Records a `library_unsynced` handoff failure (the peer's trackHash is
    /// not in the local index). Silent on the wire; surfaced in the view.
    public func reportUnsynced(trackHash: String) {
        self.updateSession { view in
            view.lastUnsynced = trackHash
        }
        self.log.debug("presence.session.library_unsynced", [
            "hash": String(trackHash.prefix(12)),
        ])
    }

    // MARK: Transitions (engine-internal)

    /// A session-capable peer started a new playing stint: the stint becomes
    /// the remote session, connected.
    func sessionPeerBecameActive(peerID: String, state: PresencePlaybackState) {
        guard let trackHash = state.trackHash, let playbackId = state.playbackId else { return }
        let peerName = self.peers[peerID]?.name ?? peerID
        self.updateSession { view in
            view.source = .remote(.init(
                peerID: peerID,
                peerName: peerName,
                reachability: .connected,
                lastKnown: .init(
                    trackHash: trackHash,
                    trackTitle: state.track,
                    positionSec: state.positionSec,
                    playbackId: playbackId,
                    status: state.status,
                    updatedAtMs: Self.nowMs()
                )
            ))
            view.lastUnsynced = nil
        }
    }

    /// A state arrived from the stint's owner: same stint playing advances
    /// the last-known position; a non-playing state from the stint's owner
    /// resolves the stint (the peer is no longer active) and the view falls
    /// back to local - this is the contract's "resolves the stint", not a
    /// disconnect.
    func sessionPeerState(peerID: String, state: PresencePlaybackState) {
        self.updateSession { view in
            guard case let .remote(stint) = view.source, stint.peerID == peerID else { return }
            if state.status == .playing, state.playbackId == stint.lastKnown.playbackId {
                view.source = .remote(.init(
                    peerID: stint.peerID,
                    peerName: stint.peerName,
                    reachability: .connected,
                    lastKnown: .init(
                        trackHash: stint.lastKnown.trackHash,
                        trackTitle: state.track,
                        positionSec: state.positionSec,
                        playbackId: stint.lastKnown.playbackId,
                        status: state.status,
                        updatedAtMs: Self.nowMs()
                    )
                ))
            } else if state.status != .playing {
                view.source = .local
            }
        }
    }

    /// The stint peer's socket closed / went reconnecting: mark unreachable,
    /// never fall back to local.
    func sessionPeerUnreachable(peerID: String) {
        self.updateSession { view in
            guard case let .remote(stint) = view.source, stint.peerID == peerID else { return }
            view.source = .remote(.init(
                peerID: stint.peerID,
                peerName: stint.peerName,
                reachability: .unreachable,
                lastKnown: stint.lastKnown
            ))
        }
    }

    /// The stint peer's socket came back: mark connected; the peer's own
    /// state updates then resolve the stint (playing advances, non-playing
    /// resolves it).
    func sessionPeerReconnected(peerID: String) {
        self.updateSession { view in
            guard case let .remote(stint) = view.source, stint.peerID == peerID else { return }
            view.source = .remote(.init(
                peerID: stint.peerID,
                peerName: stint.peerName,
                reachability: .connected,
                lastKnown: stint.lastKnown
            ))
        }
    }

    /// The stint peer is gone (goodbye, 60 s expiry, service removed): the
    /// session stays visible as last-known, never falls back to local.
    func sessionPeerGone(peerID: String) {
        self.updateSession { view in
            guard case let .remote(stint) = view.source, stint.peerID == peerID else { return }
            view.source = .remote(.init(
                peerID: stint.peerID,
                peerName: stint.peerName,
                reachability: .gone,
                lastKnown: stint.lastKnown
            ))
        }
    }

    /// Self started a local playing stint: local wins, absorbing any remote
    /// stint or in-flight takeover.
    func sessionLocalWin() {
        self.updateSession { view in
            if view.source != .local {
                view.source = .local
            }
            view.lastUnsynced = nil
        }
    }

    /// A `session_conflict` episode was detected.
    func sessionConflictDetected(deviceNames: [String]) {
        self.updateSession { view in
            view.conflict = .init(deviceNames: deviceNames, detectedAtMs: Self.nowMs())
        }
    }

    /// The conflict overlap ended.
    func sessionConflictCleared() {
        self.updateSession { view in
            view.conflict = nil
        }
    }

    // MARK: Plumbing

    private static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

    private func updateSession(_ mutate: (inout SessionView) -> Void) {
        mutate(&self.session)
        for continuation in self.sessionContinuations.withLock({ $0.values }) {
            continuation.yield(self.session)
        }
    }
}
