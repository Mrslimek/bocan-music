import Foundation
import Observability
import Presence

/// State-store for the main player surface's SHARED SESSION view (contract
/// section 8). Distinct axis from connection state: a remote stint survives
/// disconnects as `.unreachable`/`.gone`.
///
/// Transport dispatch branches on the session source: while the stint's peer
/// is connected, play/pause/next/previous/scrub are sent to the peer as
/// `command` messages; otherwise (local stint) they go to the local player
/// through the injected `localDispatch` closure (App-wired to
/// `NowPlayingViewModel`). The menu bar, mini player and media keys keep
/// calling the local player directly and are deliberately unaffected.
@MainActor
@Observable
public final class SessionViewModel {
    /// The engine-owned session view, as last published.
    public private(set) var session = SessionView(source: .local)

    /// Whether a session-capable peer owns the active stint and is still
    /// connected (transport commands dispatch remotely; local-only
    /// affordances are disabled).
    public var isRemoteConnected: Bool {
        self.session.isRemoteConnected
    }

    /// Whether any remote stint exists (connected, unreachable or gone).
    public var isRemote: Bool {
        self.session.isRemote
    }

    /// True while a handoff is being started locally.
    public var isTakeoverInFlight: Bool {
        if case .takeoverInFlight = self.session.source { return true }
        return false
    }

    @ObservationIgnored private let sendCommand: @Sendable (String, PresenceCommandAction, Double?) async -> Void
    @ObservationIgnored private let playHere: @Sendable (PeerSnapshot) async -> PresenceHandoffOutcome
    @ObservationIgnored private var localDispatch: (@Sendable (PresenceCommandAction, Double?) async -> Void)?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    /// - Parameters:
    ///   - updates: the engine's `sessionUpdates()` stream.
    ///   - sendCommand: forwards a command to one peer (the engine's
    ///     `sendCommand`).
    ///   - playHere: the App-composed handoff (resolve hash -> local track ->
    ///     seek + play), shared with the Peers window.
    public init(
        updates: AsyncStream<SessionView>,
        sendCommand: @escaping @Sendable (String, PresenceCommandAction, Double?) async -> Void,
        playHere: @escaping @Sendable (PeerSnapshot) async -> PresenceHandoffOutcome
    ) {
        self.sendCommand = sendCommand
        self.playHere = playHere
        self.watchTask = Task {
            for await session in updates {
                self.session = session
            }
        }
    }

    deinit {
        self.watchTask?.cancel()
    }

    /// Wires local transport dispatch (App: `NowPlayingViewModel` methods).
    /// Called after the local player surface exists; called once.
    public func setLocalDispatch(
        _ dispatch: @escaping @Sendable (PresenceCommandAction, Double?) async -> Void
    ) {
        self.localDispatch = dispatch
    }

    /// The stint's peer, when a remote stint exists.
    public var remotePeer: (id: String, name: String)? {
        if case let .remote(stint) = self.session.source {
            return (stint.peerID, stint.peerName)
        }
        return nil
    }

    /// Transport dispatch for the main player surface. Remote-connected ->
    /// `command` to the stint peer; local (or unreachable/gone, where views
    /// disable transport) -> the local player.
    public func dispatch(_ action: PresenceCommandAction, position: Double? = nil) async {
        if case let .remote(stint) = self.session.source, stint.reachability == .connected {
            await self.sendCommand(stint.peerID, action, position)
            return
        }
        if let localDispatch = self.localDispatch {
            await localDispatch(action, position)
        }
    }

    /// "Take over here": run the handoff for the stint's last-known track.
    /// Legal even while the stint peer is unreachable (section 8's conflict
    /// machinery covers the overlap).
    public func takeOverHere() async {
        guard case let .remote(stint) = self.session.source else { return }
        let peer = PeerSnapshot(
            id: stint.peerID,
            name: stint.peerName,
            discovery: .discovered,
            connection: stint.reachability == .connected ? .connected : .unreachable,
            playback: PresencePlaybackState(
                track: stint.lastKnown.trackTitle,
                status: stint.lastKnown.status,
                positionSec: stint.lastKnown.positionSec,
                seq: 0,
                trackHash: stint.lastKnown.trackHash,
                playbackId: stint.lastKnown.playbackId
            ),
            rttMs: nil,
            role: nil
        )
        let outcome = await self.playHere(peer)
        if outcome != .handedOff {
            self.log.warning("presence.session.takeover.failed", ["peer": stint.peerID])
        }
    }
}
