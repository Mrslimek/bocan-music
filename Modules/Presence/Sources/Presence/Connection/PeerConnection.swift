import Foundation
import Observability

// MARK: - Events toward the engine

/// Why a connection ended. The engine maps this to its reconnect policy:
/// only `.remote`, `.keepaliveTimeout`, `.handshakeTimeout` and `.dialTimeout`
/// start the backoff ladder; a superseded or goodbye-ended socket must not
/// reconnect (contract sections 3 and 5).
public enum DisconnectCause: Sendable, Equatable {
    /// The peer closed or the transport failed.
    case remote
    /// No pong within the budget of the last received pong.
    case keepaliveTimeout
    /// The handshake did not finish within its budget.
    case handshakeTimeout
    /// The socket never opened within the dial budget (dead peer's backlog).
    case dialTimeout
    /// A newer connection for the same peer id replaced this one (4003).
    case superseded
    /// We sent goodbye (engine shutdown).
    case shutdown
}

/// Everything a connection actor wants the engine to know, in order.
public enum PeerConnectionEvent: Sendable {
    /// Caller sent its hello (handshake timer armed at socket open).
    case handshakeSent
    /// Callee validated a hello and answered hello_ack.
    case handshakeCompletedCallee(peerID: String, info: PresenceHelloInfo)
    /// Caller validated the hello_ack for its dial (`peerID` is the answering
    /// peer's id from the envelope, which manual dials adopt as their real id).
    case handshakeCompletedCaller(peerID: String, peerName: String, platform: String, appVersion: String)
    /// The keepalive ping went on the wire.
    case pingSent
    /// An application-level ping arrived (already answered).
    case pingReceived
    /// A matching pong arrived; RTT is `pong.ts - ping.ts`, the local delta is
    /// our own send-to-receive time.
    case pong(rttMs: Double, localDeltaMs: Double)
    /// A pong whose replyTo matches no outstanding ping.
    case unknownPong
    /// A non-liveness message (state_update, test, goodbye) after receiver-rule
    /// processing.
    case message(PresenceMessage, envelope: PresenceEnvelope)
    /// A frame with an unknown `type`: logged and ignored, never disconnecting
    /// (contract section 6 receiver rules).
    case unknownType(PresenceEnvelope)
    /// Missing/invalid required fields: logged and ignored.
    case malformed(reason: String, type: String?)
    /// Terminal: emitted exactly once per connection, after the teardown latch.
    case closed(code: UInt16, reason: String, cause: DisconnectCause)
}

// MARK: - PeerConnection

/// One live WebSocket to one peer, in one role. Owns the handshake and all
/// per-connection liveness state, so the state dies with the transport: a
/// superseded or watchdog-closed socket's outstanding pings can never poison
/// the next handshake (the MVP's worst defect class, its defects 2/10/11).
///
/// The teardown latch makes every keepalive/timeout decision one-shot: after it
/// fires, ticks are no-ops and the socket closes exactly once.
public actor PeerConnection {
    public enum Role: Sendable, Equatable {
        case caller
        case callee
    }

    enum Phase: Sendable, Equatable {
        case dialing
        case awaitingHello
        case awaitingHelloAck
        case ready
        case closed
    }

    /// Stable identity for the engine's owner table and logging.
    public nonisolated let connID = UUID()
    /// Which side of the connection this actor drives.
    public nonisolated let role: Role

    let transport: WSTransport
    let config: PresenceConfig
    let selfID: String
    let selfName: @Sendable () -> String
    let appVersion: String
    /// For callers: the peer id the dial expected (nil for manual dials, which
    /// adopt whatever id answers).
    let expectedPeerID: String?
    let onEvent: @Sendable (PeerConnectionEvent) -> Void

    // Liveness state. All of it is per-transport: cleared at every handshake
    // completion and discarded with this actor.
    var outstandingPings: [String: (peerTS: Double, localMs: Double)] = [:]
    var lastPongAt: Date
    var lastPingSentAt: Date

    var phase: Phase
    var dialDeadline: Date?
    var ackDeadline: Date?
    var helloDeadline: Date?
    var helloSentID: String?
    /// One-shot teardown latch: once set, ticks and late transport events are
    /// no-ops and the close fires exactly once.
    var tornDown = false

    /// Transport events funnel through this stream so they reach the actor in
    /// arrival order: the sink only yields (synchronous, FIFO), and a single
    /// consumer task drains it. One unstructured Task per event would not
    /// preserve ordering across actor hops.
    struct EventPump: Sendable {
        let stream: AsyncStream<WSEvent>
        let continuation: AsyncStream<WSEvent>.Continuation
    }

    let eventPump: EventPump
    var pumpTask: Task<Void, Never>?

    /// - Parameters:
    ///   - expectedPeerID: the id the dial expected; `nil` adopts whatever
    ///     id answers (manual connect).
    public init(
        role: Role,
        transport: WSTransport,
        config: PresenceConfig,
        selfID: String,
        selfName: @escaping @Sendable () -> String,
        appVersion: String,
        expectedPeerID: String?,
        onEvent: @escaping @Sendable (PeerConnectionEvent) -> Void
    ) {
        self.role = role
        self.transport = transport
        self.config = config
        self.selfID = selfID
        self.selfName = selfName
        self.appVersion = appVersion
        self.expectedPeerID = expectedPeerID
        self.onEvent = onEvent
        let (stream, continuation) = AsyncStream.makeStream(of: WSEvent.self)
        self.eventPump = EventPump(stream: stream, continuation: continuation)
        self.phase = role == .caller ? .dialing : .awaitingHello
        self.lastPongAt = Date()
        self.lastPingSentAt = Date()
        if role == .caller {
            self.dialDeadline = Date().addingTimeInterval(config.dialTimeout)
        } else {
            self.helloDeadline = Date().addingTimeInterval(config.handshakeTimeout)
        }
    }

    // MARK: Lifecycle

    /// Binds the event sink and starts the transport. Events funnel through
    /// the stream and are handled in arrival order.
    public func start() {
        self.transport.onEvent = { [pump = self.eventPump.continuation] event in
            pump.yield(event)
        }
        let stream = self.eventPump.stream
        self.pumpTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleSocketEvent(event)
            }
        }
        self.transport.start()
    }

    // MARK: Engine tick

    /// One housekeeping tick: deadlines and keepalive. A no-op once the
    /// teardown latch is set (a decided connection is inert).
    public func tick(now: Date) {
        guard !self.tornDown, self.phase != .closed else { return }
        switch self.phase {
        case .dialing:
            if let deadline = self.dialDeadline, now >= deadline {
                // The socket never opened: cancel without a close frame (there
                // is no WS session to close) and escalate the ladder.
                self.tearDown(code: 1011, reason: "connect timeout", cause: .dialTimeout)
            }

        case .awaitingHelloAck:
            if let deadline = self.ackDeadline, now >= deadline {
                self.tearDown(code: 4002, reason: "handshake timeout", cause: .handshakeTimeout)
            }

        case .awaitingHello:
            if let deadline = self.helloDeadline, now >= deadline {
                self.tearDown(code: 4002, reason: "handshake timeout", cause: .handshakeTimeout)
            }

        case .ready:
            self.tickReady(now: now)

        case .closed:
            break
        }
    }

    private func tickReady(now: Date) {
        if now.timeIntervalSince(self.lastPingSentAt) >= self.config.pingInterval {
            self.sendPing(now: now)
        }
        // Keyed on the last RECEIVED pong, never on ping-send time: a budget
        // measured from sends can never expire (the MVP's defect 2).
        if now.timeIntervalSince(self.lastPongAt) >= self.config.pongTimeout {
            // Drop the ping bookkeeping with the transport (the MVP's defect
            // 11): a watchdog-fired socket never flows through the normal death
            // path, so stale unanswered pings must not outlive it.
            self.outstandingPings.removeAll()
            self.tearDown(code: 1000, reason: "keepalive timeout", cause: .keepaliveTimeout)
        }
    }

    // MARK: Outgoing application messages

    /// Sends a `state_update`. Called by the engine after its own bookkeeping
    /// (seq bump or post-handshake snapshot).
    public func sendState(_ state: PresencePlaybackState) {
        guard !self.tornDown, self.phase == .ready else { return }
        self.send(.stateUpdate(state), replyTo: nil)
    }

    /// Sends a fire-and-forget `command` (contract section 6). No reply is
    /// expected; the effect is observable through the peer's next
    /// `state_update`.
    public func sendCommand(_ command: PresenceCommand) {
        guard !self.tornDown, self.phase == .ready else { return }
        self.send(.command(command), replyTo: nil)
    }

    /// Sends a `queue` snapshot (contract section 9). Fire-and-forget, like
    /// `sendCommand`.
    public func sendQueue(_ message: PresenceQueueMessage) {
        guard !self.tornDown, self.phase == .ready else { return }
        self.send(.queue(message), replyTo: nil)
    }

    /// Sends `goodbye`, gives the frame a short flush window, then closes 1000.
    public func goodbye(reason: String) async {
        guard !self.tornDown else { return }
        self.send(.goodbye(reason: reason), replyTo: nil)
        // The close frame must not overtake the goodbye text frame.
        try? await Task.sleep(nanoseconds: 150_000_000)
        self.tearDown(code: 1000, reason: reason, cause: .shutdown)
    }

    /// Newest-wins (contract section 3): the engine adopted a newer socket for
    /// this peer and closes this one with 4003. No reconnect follows on the
    /// superseded side.
    public func supersede() {
        self.tearDown(code: 4003, reason: "superseded by newer connection", cause: .superseded)
    }

    /// Engine-initiated close in response to a peer's goodbye or a discovery
    /// removal; cause `.remote` (the engine owns the reconnect decision).
    public func closeLocally(code: UInt16, reason: String, cause: DisconnectCause) {
        self.tearDown(code: code, reason: reason, cause: cause)
    }

    /// Bound-shutdown fallback: past the goodbye deadline the remaining sockets
    /// are simply cancelled, still without reconnect scheduling.
    public func cancelForShutdown() {
        self.tearDown(code: 1000, reason: "app shutdown", cause: .shutdown)
    }

    /// Health for the discovery-hint guard: connected with a pong inside
    /// `maxPongAge` means a removal hint must not tear this peer down.
    public func isHealthy(maxPongAge: TimeInterval, now: Date) -> Bool {
        guard self.phase == .ready, !self.tornDown else { return false }
        return now.timeIntervalSince(self.lastPongAt) <= maxPongAge
    }

    // MARK: Teardown (one-shot)

    /// Hands the event stream out once; the pump task consumes it.
    private func eventPumpStream() -> AsyncStream<WSEvent> {
        self.eventPump.stream
    }

    private func tearDown(code: UInt16, reason: String, cause: DisconnectCause) {
        guard !self.tornDown else { return }
        self.tornDown = true
        self.phase = .closed
        // The pump drains in order and exits here, releasing the connection.
        self.eventPump.continuation.finish()
        switch cause {
        case .dialTimeout:
            self.transport.cancel()

        default:
            self.transport.close(code: code, reason: reason)
        }
        self.onEvent(.closed(code: code, reason: reason, cause: cause))
    }

    // MARK: Socket events

    func handleSocketEvent(_ event: WSEvent) {
        guard !self.tornDown else { return }
        switch event {
        case .open:
            self.onOpen()

        case let .text(text):
            self.onText(text)

        case let .remoteClose(code, reason):
            self.tearDown(code: code, reason: reason.isEmpty ? "closed by peer" : reason, cause: .remote)

        case let .failed(detail):
            self.tearDown(code: 1006, reason: detail, cause: .remote)
        }
    }

    private func onOpen() {
        switch self.role {
        case .caller:
            // 5 s hello_ack budget, measured from socket open (contract section 3).
            self.ackDeadline = Date().addingTimeInterval(self.config.handshakeTimeout)
            self.sendCallerHello()

        case .callee:
            break // waiting for hello; helloDeadline was armed at accept
        }
    }

    private func sendCallerHello() {
        let info = PresenceHelloInfo(name: self.selfName(), platform: "macos", appVersion: self.appVersion)
        let envelope = WireCodec.envelope(from: self.selfID, nowMs: Self.nowMs())
        self.helloSentID = envelope.id
        guard let text = try? WireCodec.encode(.hello(info), envelope: envelope) else { return }
        self.phase = .awaitingHelloAck
        self.transport.send(text)
        self.onEvent(.handshakeSent)
    }

    static func nowMs() -> Double {
        Date().timeIntervalSince1970 * 1000
    }
}
