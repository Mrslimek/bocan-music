import Foundation
import Synchronization
import Network
import Observability
import Playback

/// The top-level Presence actor (docs/design-spec/PROTOCOL.md): owns the mDNS
/// advertiser + browser, the WebSocket listener and client dials, one
/// `PeerConnection` per peer (handshake, keepalive, tie-break, newest-wins),
/// the reconnect ladder, and the `PeerDirectory` snapshot stream.
///
/// Lifecycle mirrors `SyncServer`: constructed unconditionally by the App,
/// started only when the `presence.enabled` preference is on (default off),
/// stopped at quit with goodbye + unregister inside the shutdown budget.
public actor PresenceEngine {
    // MARK: Dependencies

    let identity: PresenceIdentity
    let appVersion: String
    let config: PresenceConfig
    let player: QueuePlayer?
    let directory = PeerDirectoryBroadcaster()
    let log: AppLogger

    /// The inbound-command gate: true when the local user allows peers to
    /// control playback (contract section 6; default on). Outbound commands
    /// are always allowed.
    let controlEnabled: @Sendable () -> Bool
    /// Applies an inbound command to the local player. Returns false when the
    /// action is not supported by this build, which the engine logs as
    /// `command_ignored reason=unsupported`.
    let commandExecutor: @Sendable (PresenceCommandAction, Double?) async -> Bool
    /// Resolves the shared-session `trackHash` for a local track (contract
    /// section 8); nil when the track has no hashable file.
    let trackHashProvider: @Sendable (Int64) async -> String?
    /// Fired when a session-capable peer transitions to playing with a fresh
    /// stint. The App implements the pause-on-peer-active policy (section 8's
    /// recommended default); the engine never mutates playback.
    let onPeerBecameActive: (@Sendable (
        _ peerID: String,
        _ peerName: String,
        _ trackHash: String?,
        _ positionSec: Double,
        _ playbackId: String
    ) async -> Void)?
    /// Fired when two-or-more playing devices stay overlapped past the
    /// handoff grace. The engine logs the event; the callback is for
    /// player-level surfacing. Never auto-resolved.
    let onSessionConflict: (@Sendable (_ peerIDs: [String]) async -> Void)?

    // MARK: Transports

    var listener: PresenceListener?
    var browser: PresenceBrowser?
    var netServiceBrowser: NetServicePresence?
    /// The stack the listener actually settled on (the config value, or the
    /// BSD fallback when the NW probe failed). Discovery and dials follow it.
    var discoveryStack: PresenceTransportStack = .networkFramework
    /// One queue for sockets and the browser; Network callbacks are confined here.
    let socketQueue = DispatchQueue(label: "io.cloudcauldron.bocan.presence.sockets")

    // MARK: Peer state

    struct PeerRecord {
        var id: String
        var name: String
        var endpoint: NWEndpoint?
        var lastAnnounce: Date
        var discovery: PeerDiscoveryState = .discovered
        var connection: PeerConnectionState = .idle
        var backoffIndex = 0
        var nextDialAt: Date?
        var suppressReconnect = false
        var lastSeenSeq: Int?
        var playback: PresencePlaybackState?
        var lastRttMs: Double?
        var pendingRemovalSince: Date?
        /// Resolved host/port for the BSD dial path (NetService announcements
        /// and manual connects).
        var hostPort: PresenceHostPort?
        /// Manual dials carry a provisional id until the handshake reveals the
        /// real one; they are exempt from discovery expiry.
        var isManual = false
    }

    var peers: [String: PeerRecord] = [:]
    /// Live connections by peer id (or provisional manual key pre-handshake).
    var connections: [String: PeerConnection] = [:]
    /// Inbound sockets that have not said hello yet, keyed by connection id.
    var pendingInbound: [UUID: PeerConnection] = [:]
    /// Which peer key each connection currently belongs to; a missing entry
    /// means a superseded or dead socket whose late events are dropped.
    var connOwner: [UUID: String] = [:]
    /// Received message ids per peer (contract: duplicate window of 128).
    var seenMessageIDs: [String: [String]] = [:]

    // MARK: Own playback state

    var ownState: PresencePlaybackState = .empty
    var lastPositionBroadcastAt: Date = .distantPast
    /// The current playback stint id (contract section 8): fresh on every
    /// track start and takeover; kept across a pause-to-resume.
    var ownPlaybackID: String?
    /// The track hash of the last stint we started, for the freshness rule.
    var lastStintTrackHash: String?
    /// Session-conflict observation: first moment >= 2 devices were playing,
    /// and whether the event already fired for this episode.
    var conflictSince: Date?
    var conflictFired = false
    /// The observable session view (contract section 8), owned by the engine
    /// and published on `sessionUpdates()`.
    var session = SessionView(source: .local)
    let sessionContinuations = Mutex<[UUID: AsyncStream<SessionView>.Continuation]>([:])
    /// The view to restore when a takeover attempt fails locally.
    var takeoverPrevious: SessionView?
    var tap: PlaybackTap?

    // MARK: Lifecycle

    var running = false
    var tickTask: Task<Void, Never>?
    var rebrowseTask: Task<Void, Never>?

    // MARK: Init

    /// - Parameters:
    ///   - player: the queue player to tap for our own playback state; `nil`
    ///     in protocol tests that drive state by hand.
    ///   - identity: the persisted device id + display-name closure.
    ///   - appVersion: reported in hello/hello_ack, injected from the App.
    ///   - config: contract tunables; tests inject faster clocks.
    ///   - log: injectable so tests can assert protocol events.
    public init(
        player: QueuePlayer?,
        identity: PresenceIdentity,
        appVersion: String,
        config: PresenceConfig = .default,
        controlEnabled: @escaping @Sendable () -> Bool = { true },
        commandExecutor: @escaping @Sendable (PresenceCommandAction, Double?) async -> Bool = { _, _ in false },
        trackHashProvider: @escaping @Sendable (Int64) async -> String? = { _ in nil },
        onPeerBecameActive: (@Sendable (
            _ peerID: String,
            _ peerName: String,
            _ trackHash: String?,
            _ positionSec: Double,
            _ playbackId: String
        ) async -> Void)? = nil,
        onSessionConflict: (@Sendable (_ peerIDs: [String]) async -> Void)? = nil,
        log: AppLogger = AppLogger.make(.presence)
    ) {
        self.player = player
        self.identity = identity
        self.appVersion = appVersion
        self.config = config
        self.controlEnabled = controlEnabled
        self.commandExecutor = commandExecutor
        self.trackHashProvider = trackHashProvider
        self.onPeerBecameActive = onPeerBecameActive
        self.onSessionConflict = onSessionConflict
        self.log = log
    }

    // MARK: Public surface

    /// Whether `start` has run and `stop` has not.
    public var isRunning: Bool {
        self.running
    }

    /// Builds the playback tap with the session hash provider wired in.
    private func makePlaybackTap(player: QueuePlayer) async -> PlaybackTap {
        let trackHashProvider = self.trackHashProvider
        return PlaybackTap(
            player: player,
            trackHashProvider: { trackID in
                await trackHashProvider(trackID)
            },
            onChange: { [weak self] state in
                await self?.applyOwnState(state)
            }
        )
    }

    /// Starts the listener, the mDNS advertiser + browser (when enabled), the
    /// playback tap, and the housekeeping tick. Idempotent.
    public func start() async throws {
        guard !self.running else { return }
        self.running = true
        // Dials need a stack even without a bound listener; .automatic only
        // resolves when a listener actually ran the NW probe.
        self.discoveryStack = Self.resolvedStack(for: self.config.transportStack)

        var port: UInt16 = 0
        if self.config.bindsListener {
            let listener = PresenceListener(configuredStack: self.config.transportStack)
            await listener.setAcceptHandler { [weak self] transport in
                guard let self else { return }
                Task { await self.acceptInbound(transport) }
            }
            self.listener = listener

            let serviceName = self.config.advertiseName ?? self.identity.name()
            let txt = PresenceListener.txtRecord(
                id: self.identity.id,
                name: serviceName,
                version: self.config.protocolVersion
            )
            port = try await listener.start(
                advertise: self.config.usesDiscovery,
                serviceName: serviceName,
                txt: txt
            )
            self.discoveryStack = await listener.effectiveStack
        }

        if self.config.usesDiscovery {
            await self.startBrowsing()
            self.rebrowseTask = self.makeRebrowseTask()
        }

        if let player = self.player {
            let tap = await self.makePlaybackTap(player: player)
            await tap.start()
            self.tap = tap
        }

        self.tickTask = Task { [weak self] in
            await self?.runTicks()
        }

        self.log.debug("presence.start", [
            "peer": self.identity.id,
            "port": String(port),
            "discovery": String(self.config.usesDiscovery),
        ])
        self.publishSnapshot()
    }

    /// Sends goodbye to connected peers, closes everything, withdraws the
    /// advertisement and stops the browser. Idempotent, and bounded well under
    /// the shutdown budget (each goodbye flushes for 0.15 s; the loop gives up
    /// past the deadline and cancels the rest).
    public func stop() async {
        guard self.running else { return }
        self.running = false

        self.tickTask?.cancel()
        self.tickTask = nil
        self.rebrowseTask?.cancel()
        self.rebrowseTask = nil
        await self.tap?.stop()
        self.tap = nil

        let deadline = Date().addingTimeInterval(1.2)
        let connected = Array(self.connections.values)
        self.connections.removeAll()
        self.pendingInbound.removeAll()
        self.connOwner.removeAll()
        for connection in connected {
            if Date() < deadline {
                await connection.goodbye(reason: GoodbyeReason.appShutdown)
            } else {
                await connection.cancelForShutdown()
            }
        }

        await self.browser?.stop()
        self.browser = nil
        self.netServiceBrowser?.stop()
        self.netServiceBrowser = nil
        await self.listener?.stop()
        self.listener = nil
        self.log.debug("presence.stop")
        self.publishSnapshot()
    }

    /// Re-registers the Bonjour service and re-browses after a system wake,
    /// when either may have been dropped. No-op while off.
    public func reAdvertise() async {
        guard self.running else { return }
        let serviceName = self.config.advertiseName ?? self.identity.name()
        let txt = PresenceListener.txtRecord(
            id: self.identity.id,
            name: serviceName,
            version: self.config.protocolVersion
        )
        await self.listener?.reAdvertise(serviceName: serviceName, txt: txt)
        await self.browser?.restart()
        self.log.debug("presence.readvertise")
    }

    private static func resolvedStack(for stack: PresenceTransportStack) -> PresenceTransportStack {
        stack == .automatic ? .networkFramework : stack
    }

    /// The bound listener port, or nil while stopped (tests, diagnostics).
    public func listenerPort() async -> UInt16? {
        await self.listener?.port
    }

    /// This Mac's identity + running state for Settings.
    public func selfInfo() async -> SelfSnapshot {
        await SelfSnapshot(
            id: self.identity.id,
            name: self.identity.name(),
            port: self.listener?.port,
            running: self.running
        )
    }

    /// Per-subscriber stream of the peer list (Peers window, Settings).
    public func peerUpdates() -> AsyncStream<[PeerSnapshot]> {
        self.directory.subscribe()
    }

    /// Forces the next own-state report to open a fresh playback stint
    /// (contract section 8: a takeover is always a new stint, even when the
    /// local player resumes the same track). The handoff UI calls this
    /// before starting local playback from a peer's position.
    public func beginPlaybackStint() {
        self.ownPlaybackID = nil
    }

    /// Sends a fire-and-forget remote-control command to one connected peer
    /// (contract section 6). Outbound commands are always allowed; the peer
    /// applies or ignores them on its side.
    public func sendCommand(peerID: String, action: PresenceCommandAction, positionSec: Double? = nil) async {
        guard let connection = self.connections[peerID] else {
            self.log.debug("presence.command_send.failed", [
                "peer": peerID,
                "action": action.rawValue,
                "reason": "not connected",
            ])
            return
        }
        await connection.sendCommand(PresenceCommand(action: action.rawValue, positionSec: positionSec))
        self.log.debug("presence.command_sent", [
            "peer": peerID,
            "name": self.peers[peerID]?.name ?? peerID,
            "action": action.rawValue,
            "pos": positionSec.map { String(format: "%.1f", $0) } ?? "-",
        ])
    }

    /// Manual connect (contract section 3: whoever entered the address is the
    /// caller, regardless of id ordering). Used by tests and, later, UI.
    public func connectManual(host: String, port: UInt16) async throws {
        guard !host.isEmpty else {
            throw PresenceError.invalidManualTarget("\(host):\(port)")
        }
        let key = "manual:\(host):\(port)"
        if let existing = self.connections[key] {
            self.log.debug("presence.disconnect", ["peer": key, "reason": "superseded by newer manual connect (4003)"])
            Task { await existing.supersede() }
        }
        var record = self.peers[key] ?? PeerRecord(id: key, name: "\(host):\(port)", endpoint: nil, lastAnnounce: Date())
        record.isManual = true
        record.discovery = .inboundOnly
        record.connection = .connecting
        record.suppressReconnect = false
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PresenceError.invalidManualTarget("\(host):\(port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        record.endpoint = endpoint
        record.hostPort = PresenceHostPort(host: host, port: port)
        self.peers[key] = record
        self.log.debug("presence.connect_attempt", ["peer": key, "addr": "\(host):\(port)", "via": "manual"])
        await self.dial(peerID: key, endpoint: endpoint, hostPort: record.hostPort, expectedPeerID: nil)
        self.publishSnapshot()
    }

    // MARK: Goodbye reasons (contract section 6)

    enum GoodbyeReason {
        static let appShutdown = "app_shutdown"
        static let userClose = "user_close"
    }
}
