import Foundation
import Observability
import Presence

// MARK: - Handoff

/// The outcome of a "Play here" handoff attempt (contract section 8 takeover
/// flow). `libraryUnsynced` is the contract's local failure: the peer's
/// trackHash is not in the local index, nothing was sent on the wire.
public enum PresenceHandoffOutcome: Sendable, Equatable {
    case handedOff
    case libraryUnsynced
    case failed
}

// MARK: - PeersViewModel

/// State-store for the Presence Peers window: follows the engine's directory
/// stream so the window shows connected and discovered peers with their live
/// playback state. A protocol-free view model over the engine.
@MainActor
@Observable
public final class PeersViewModel {
    /// The live peer list from the engine's directory stream.
    public private(set) var peers: [PeerSnapshot] = []
    /// This Mac's display name.
    public private(set) var selfName = ""
    /// This Mac's persisted device id.
    public private(set) var selfID = ""
    /// Whether the Presence engine is currently running.
    public private(set) var isRunning = false

    @ObservationIgnored private let engine: PresenceEngine
    /// The App-composed handoff (resolve hash -> local track -> seek + play).
    @ObservationIgnored private let playHere: @Sendable (PeerSnapshot) async -> PresenceHandoffOutcome
    /// The last handoff failure, shown beside the peer list until the next
    /// attempt or the auto-clear.
    public var handoffMessage: HandoffMessage?

    /// A user-facing handoff failure message.
    public enum HandoffMessage: Equatable, Sendable {
        /// Contract section 8 `library_unsynced`: the peer's trackHash is not
        /// in the local index.
        case libraryUnsynced
        /// Local playback could not be started.
        case failed
    }

    @ObservationIgnored private nonisolated(unsafe) var watchTask: Task<Void, Never>?

    /// - Parameter engine: the engine the App wired in `buildGraph`.
    public init(
        engine: PresenceEngine,
        playHere: @escaping @Sendable (PeerSnapshot) async -> PresenceHandoffOutcome
    ) {
        self.engine = engine
        self.playHere = playHere
    }

    deinit {
        self.watchTask?.cancel()
    }

    /// Sends a remote-control command to one peer (fire-and-forget; the
    /// peer's next `state_update` shows the effect).
    public func sendCommand(to peer: PeerSnapshot, action: PresenceCommandAction) async {
        await self.engine.sendCommand(peerID: peer.id, action: action)
    }

    /// "Play here": take over the peer's current track at the peer's position
    /// from the local library. Failures surface as a user-facing message that
    /// auto-clears; per the contract a missing hash stays silent on the wire.
    public func playHere(_ peer: PeerSnapshot) async {
        let outcome = await self.playHere(peer)
        switch outcome {
        case .handedOff:
            self.handoffMessage = nil

        case .libraryUnsynced:
            self.handoffMessage = .libraryUnsynced

        case .failed:
            self.handoffMessage = .failed
        }
        if self.handoffMessage != nil {
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled {
                    self.handoffMessage = nil
                }
            }
        }
    }

    /// Loads self identity and follows the peer list. Call from `.task`; runs
    /// until the view goes away.
    public func start() async {
        let info = await self.engine.selfInfo()
        self.selfName = info.name
        self.selfID = info.id
        self.isRunning = info.running
        guard self.watchTask == nil else { return }
        let engine = self.engine
        self.watchTask = Task {
            let updates = await engine.peerUpdates()
            for await peers in updates {
                self.peers = peers
            }
        }
    }
}
