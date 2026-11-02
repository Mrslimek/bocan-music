import Foundation
import Observability
import Presence
import Testing

// MARK: - MockWSTransport

/// Scriptable `WSTransport` for connection-actor tests: records every frame
/// the connection sends and lets the test push frames into it.
final class MockWSTransport: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sentTexts: [String] = []
    private var closeFrame: (code: UInt16, reason: String)?
    private var cancelledFlag = false
    private var startedFlag = false
    /// When true (the default), `start()` behaves like a socket that opened.
    var opensOnStart = true
    /// Frames delivered from the peer before `.open`, for scripted sockets.
    var queuedIncoming: [WSEvent] = []

    // Storage is separate from the `onEvent` accessor: the getter runs inside
    // withLock, and NSLock is not reentrant, so the body must not read the
    // property itself.
    private var eventSinkStorage: (@Sendable (WSEvent) -> Void)?
    private static let noSink: @Sendable (WSEvent) -> Void = { _ in }

    var onEvent: @Sendable (WSEvent) -> Void {
        get { self.lock.withLock { self.eventSinkStorage } ?? Self.noSink }
        set { self.lock.withLock { self.eventSinkStorage = newValue } }
    }

    private func sink() -> (@Sendable (WSEvent) -> Void)? {
        self.lock.withLock { self.eventSinkStorage }
    }

    func start() {
        self.lock.withLock { self.startedFlag = true }
        guard self.opensOnStart else { return }
        let queued = self.lock.withLock { () -> [WSEvent] in
            let events = self.queuedIncoming
            self.queuedIncoming = []
            return events
        }
        self.emit(.open)
        for event in queued {
            self.emit(event)
        }
    }

    func send(_ text: String) {
        self.lock.withLock { self.sentTexts.append(text) }
    }

    func close(code: UInt16, reason: String) {
        self.lock.withLock { self.closeFrame = (code, reason) }
    }

    func cancel() {
        self.lock.withLock { self.cancelledFlag = true }
    }

    // MARK: Test controls

    func emit(_ event: WSEvent) {
        self.sink()?(event)
    }

    /// Delivers one text frame from the peer.
    func deliver(_ text: String) {
        self.emit(.text(text))
    }

    /// Delivers a remote close frame (as if the peer closed first).
    func deliverRemoteClose(code: UInt16, reason: String) {
        self.emit(.remoteClose(code: code, reason: reason))
    }

    var sent: [String] {
        self.lock.withLock { self.sentTexts }
    }

    var closeSent: (code: UInt16, reason: String)? {
        self.lock.withLock { self.closeFrame }
    }

    var cancelled: Bool {
        self.lock.withLock { self.cancelledFlag }
    }

    var started: Bool {
        self.lock.withLock { self.startedFlag }
    }

    /// The JSON dictionary of the n-th frame we sent.
    func sentObject(at index: Int) -> [String: Any]? {
        guard index < self.sent.count,
              let data = self.sent[index].data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    func reset() {
        self.lock.withLock {
            self.sentTexts = []
            self.closeFrame = nil
            self.cancelledFlag = false
        }
    }
}

// MARK: - EventCollector

/// Thread-safe sink for `PeerConnectionEvent`s with bounded polling.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PeerConnectionEvent] = []

    func append(_ event: PeerConnectionEvent) {
        self.lock.withLock { self.events.append(event) }
    }

    var all: [PeerConnectionEvent] {
        self.lock.withLock { self.events }
    }

    var closed: PeerConnectionEvent? {
        self.all.first { event in
            if case .closed = event {
                return true
            }
            return false
        }
    }

    var closedCount: Int {
        self.all.filter { event in
            if case .closed = event {
                return true
            }
            return false
        }.count
    }

    var pongEvents: [Double] {
        self.all.compactMap { event in
            if case let .pong(rttMs, _) = event {
                return rttMs
            }
            return nil
        }
    }
}

// MARK: - Polling

/// Bounded-deadline polling for async engine/actor work (house rule: no fixed
/// sleeps). Returns false when the condition never held.
func waitUntil(within seconds: Double = 10, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

// MARK: - Harness

enum Harness {
    static let testConfig = PresenceConfig(
        pingInterval: 0.2,
        pongTimeout: 0.8,
        handshakeTimeout: 0.8,
        dialTimeout: 0.8,
        peerExpiry: 2.0,
        removalDebounce: 0.3,
        healthyPongAge: 1.0,
        tickInterval: 0.1,
        usesDiscovery: false,
        bindsListener: false
    )

    static func identity(id: String, name: String) -> PresenceIdentity {
        PresenceIdentity(id: id) { name }
    }

    /// An engine with an isolated log store, so protocol-event assertions never
    /// race other tests over `LogStore.shared`.
    static func makeEngine(
        selfID: String,
        name: String,
        config: PresenceConfig = Self.testConfig,
        controlEnabled: @escaping @Sendable () -> Bool = { true },
        executor: @escaping @Sendable (PresenceCommandAction, Double?) async -> Bool = { _, _ in true },
        onPeerBecameActive: (@Sendable (
            _ peerID: String,
            _ peerName: String,
            _ trackHash: String?,
            _ positionSec: Double,
            _ playbackId: String
        ) async -> Void)? = nil,
        onSessionConflict: (@Sendable (_ peerIDs: [String]) async -> Void)? = nil,
        trackHashProvider: @escaping @Sendable (Int64) async -> String? = { _ in nil },
        store: LogStore? = nil
    ) -> PresenceEngine {
        let log = store.map { store in AppLogger(category: .presence, store: store) } ?? AppLogger.make(.presence)
        return PresenceEngine(
            player: nil,
            identity: Self.identity(id: selfID, name: name),
            appVersion: "test",
            config: config,
            controlEnabled: controlEnabled,
            commandExecutor: executor,
            trackHashProvider: trackHashProvider,
            onPeerBecameActive: onPeerBecameActive,
            onSessionConflict: onSessionConflict,
            log: log
        )
    }
}

// MARK: - PairedTransport

/// Two in-memory transports wired to each other: `send` delivers to the peer's
/// event sink as a text frame, `close` as a remote close. This exercises the
/// full protocol stack between two engines without NWListener, which cannot
/// bind inside restricted test environments (verified separately).
final class PairedTransport: WSTransport, @unchecked Sendable {
    // Storage separate from the accessor: the getter runs inside withLock and
    // NSLock is not reentrant.
    private var sinkStorage: (@Sendable (WSEvent) -> Void)?
    private static let noSink: @Sendable (WSEvent) -> Void = { _ in }
    private weak var peer: PairedTransport?
    private let lock = NSLock()
    private var sentTexts: [String] = []
    private var startedFlag = false

    var onEvent: @Sendable (WSEvent) -> Void {
        get { self.lock.withLock { self.sinkStorage } ?? Self.noSink }
        set { self.lock.withLock { self.sinkStorage = newValue } }
    }

    private func sink() -> (@Sendable (WSEvent) -> Void)? {
        self.lock.withLock { self.sinkStorage }
    }

    static func pair() -> (PairedTransport, PairedTransport) {
        let caller = PairedTransport()
        let callee = PairedTransport()
        caller.peer = callee
        callee.peer = caller
        return (caller, callee)
    }

    func start() {
        self.lock.withLock { self.startedFlag = true }
        // An adopted inbound socket is already open; deliver `.open` on the
        // next hop so the callee begins awaiting hello.
        self.emit(.open)
    }

    func send(_ text: String) {
        self.lock.withLock { self.sentTexts.append(text) }
        self.peer?.receive(text)
    }

    func close(code: UInt16, reason: String) {
        self.peer?.emit(.remoteClose(code: code, reason: reason))
    }

    func cancel() {
        self.peer?.emit(.failed("cancelled"))
    }

    private func receive(_ text: String) {
        self.emit(.text(text))
    }

    func emit(_ event: WSEvent) {
        self.sink()?(event)
    }

    var sent: [String] {
        self.lock.withLock { self.sentTexts }
    }

    var started: Bool {
        self.lock.withLock { self.startedFlag }
    }
}
