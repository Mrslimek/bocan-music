import Foundation
import Network
import Observability
import Synchronization
import Testing
@testable import Presence

// MARK: - Loopback integration

/// Two real engines in one process over one protocol session: handshake,
/// state exchange both ways, keepalive with RTT, and a clean goodbye.
/// Bounded-deadline polling throughout; no external network.
@Suite(.serialized)
struct LoopbackIntegrationTests {
    private static let loopbackConfig = PresenceConfig(
        pingInterval: 0.3,
        pongTimeout: 2.0,
        handshakeTimeout: 3.0,
        dialTimeout: 3.0,
        peerExpiry: 60,
        removalDebounce: 0.5,
        healthyPongAge: 3.0,
        tickInterval: 0.05,
        usesDiscovery: false,
        bindsListener: false
    )

    /// The listener loopback binds for real; only the mDNS layer stays off.
    private static let socketConfig = PresenceConfig(
        pingInterval: 0.3,
        pongTimeout: 2.0,
        handshakeTimeout: 3.0,
        dialTimeout: 3.0,
        peerExpiry: 60,
        removalDebounce: 0.5,
        healthyPongAge: 3.0,
        tickInterval: 0.05,
        usesDiscovery: false,
        bindsListener: true
    )

    // MARK: Two engines over an in-memory socket pair

    @Test
    func twoEngineHandshakeStateKeepaliveAndGoodbye() async throws {
        let storeA = LogStore(capacity: 2000)
        let storeB = LogStore(capacity: 2000)
        let engineA = Harness.makeEngine(selfID: "loop-aaa", name: "BocanA", config: Self.loopbackConfig, store: storeA)
        let engineB = Harness.makeEngine(selfID: "loop-zzz", name: "BocanB", config: Self.loopbackConfig, store: storeB)

        try await engineA.start()
        try await engineB.start()

        let (sideA, sideB) = PairedTransport.pair()
        // Manual semantics (contract section 3): the side that "entered the
        // address" is the caller regardless of id ordering.
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)

        await Self.assertSessionEstablished(
            engineA: engineA,
            engineB: engineB,
            peerAID: "loop-aaa",
            peerBID: "loop-zzz",
            within: 8
        )

        // 4. Clean goodbye: A stops, B receives goodbye and does NOT schedule
        // a reconnect (goodbye = gone; the MVP's defect 3).
        await engineA.stop()
        await Self.assertGoodbyeWithoutReconnect(engineB: engineB, storeB: storeB, peerAID: "loop-aaa")

        await engineB.stop()
    }

    /// Phases 1-3: handshake under the real peer ids, the post-handshake state
    /// snapshots both ways, and answered pings with recorded RTT.
    private static func assertSessionEstablished(
        engineA: PresenceEngine,
        engineB: PresenceEngine,
        peerAID: String,
        peerBID: String,
        within: Double
    ) async {
        let aConnected = await waitUntil(within: within) { [engineA] in
            await (engineA.currentPeersForTesting()).contains {
                $0.id == peerBID && $0.connection == .connected
            }
        }
        #expect(aConnected)
        let bConnected = await waitUntil(within: 4) { [engineB] in
            await (engineB.currentPeersForTesting()).contains {
                $0.id == peerAID && $0.connection == .connected
            }
        }
        #expect(bConnected)

        let aSawBState = await waitUntil(within: 4) { [engineA] in
            await (engineA.currentPeersForTesting()).first { $0.id == peerBID }?.playback != nil
        }
        #expect(aSawBState)
        let bSawAState = await waitUntil(within: 4) { [engineB] in
            await (engineB.currentPeersForTesting()).first { $0.id == peerAID }?.playback != nil
        }
        #expect(bSawAState)

        let aHasRTT = await waitUntil(within: 8) { [engineA] in
            await (engineA.currentPeersForTesting()).first { $0.id == peerBID }?.rttMs != nil
        }
        #expect(aHasRTT)
        let bHasRTT = await waitUntil(within: 8) { [engineB] in
            await (engineB.currentPeersForTesting()).first { $0.id == peerAID }?.rttMs != nil
        }
        #expect(bHasRTT)
    }

    /// The goodbye leg: B logs the goodbye, drops to unreachable, and the
    /// reconnect ladder stays silent.
    private static func assertGoodbyeWithoutReconnect(
        engineB: PresenceEngine,
        storeB: LogStore,
        peerAID: String
    ) async {
        let goodbyeLogged = await waitUntil(within: 8) { [storeB] in
            storeB.snapshot().contains { $0.message.contains("goodbye_recv") }
        }
        #expect(goodbyeLogged)
        let bDisconnected = await waitUntil(within: 4) { [engineB] in
            await (engineB.currentPeersForTesting()).first { $0.id == peerAID }?.connection == .unreachable
        }
        #expect(bDisconnected)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let reconnects = storeB.snapshot().filter { $0.message.contains("reconnect_scheduled") }
        #expect(reconnects.isEmpty)
    }

    // MARK: Remote command over the in-memory loopback

    /// A sends `pause`; B's executor applies it to B's own state and the
    /// resulting `state_update` broadcast reaches A: the full outbound ->
    /// inbound -> apply -> observable-effect loop of contract section 6.
    @Test
    func commandLoopbackPauseFlipsPeerStateAndBroadcasts() async throws {
        let storeA = LogStore(capacity: 2000)
        let storeB = LogStore(capacity: 2000)
        // B's executor flips B's own playback state, the same shape as the
        // app-side mapping (the player applies, the tap broadcasts).
        let target = EngineBox()
        let engineB = Self.commandPeer(executorTarget: target, store: storeB)
        let engineA = Harness.makeEngine(selfID: "loop-aaa", name: "BocanA", config: Self.loopbackConfig, store: storeA)
        target.target = engineB

        try await engineA.start()
        try await engineB.start()

        let (sideA, sideB) = PairedTransport.pair()
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)

        let aConnected = await waitUntil(within: 8) { [engineA] in
            await (engineA.currentPeersForTesting()).contains {
                $0.id == "loop-zzz" && $0.connection == .connected
            }
        }
        #expect(aConnected)

        // The command itself.
        await engineA.sendCommand(peerID: "loop-zzz", action: .pause)
        let sent = await waitUntil(within: 4) { [storeA] in
            storeA.snapshot().contains { $0.message.contains("command_sent") }
        }
        #expect(sent)
        let received = await waitUntil(within: 4) { [storeB] in
            storeB.snapshot().contains { $0.message.contains("command_recv") }
        }
        #expect(received)

        // Observable effect: B's state broadcast reaches A as paused.
        let aSeesPaused = await waitUntil(within: 4) { [engineA] in
            await (engineA.currentPeersForTesting()).first { $0.id == "loop-zzz" }?.playback?.status == .paused
        }
        #expect(aSeesPaused)

        // No reply message exists: exactly one command frame crossed the wire.
        let bCommandFrames = storeB.snapshot().filter { $0.message.contains("command_recv") }
        #expect(bCommandFrames.count == 1)

        await engineA.stop()
        await engineB.stop()
    }

    /// The command-receiver engine: its executor flips its own playback
    /// state so the broadcast loop is observable end to end.
    /// A copyable reference box so the executor can reach the engine it
    /// belongs to (the Mutex type is noncopyable and cannot be captured by an
    /// escaping closure).
    final class EngineBox: @unchecked Sendable {
        var target: PresenceEngine?
    }

    private static func commandPeer(
        executorTarget target: EngineBox,
        store: LogStore
    ) -> PresenceEngine {
        Harness.makeEngine(
            selfID: "loop-zzz",
            name: "BocanB",
            config: Self.loopbackConfig,
            executor: { _, position in
                guard let target = target.target else { return false }
                await target.applyOwnStateForTesting(
                    PresencePlaybackState(
                        track: "Remote Track",
                        status: .paused,
                        positionSec: position ?? 0,
                        seq: 0
                    )
                )
                return true
            },
            store: store
        )
    }

    // MARK: Two engines over real sockets (BSD fallback stack)

    /// The primary real-socket integration: engine B serves over the POSIX
    /// BSD listener + RFC 6455 server, engine A dials it over the BSD client,
    /// and the full protocol session runs over real loopback sockets. Forced
    /// `.bsdSocket` so it binds and runs everywhere, including where the
    /// Network.framework listen path is broken (ADR-097 amendment).
    @Test
    func listenerLoopbackOverBSDSockets() async throws {
        let storeA = LogStore(capacity: 2000)
        let storeB = LogStore(capacity: 2000)
        var bsdConfig = Self.socketConfig
        bsdConfig = PresenceConfig(
            pingInterval: 0.3,
            pongTimeout: 2.0,
            handshakeTimeout: 3.0,
            dialTimeout: 3.0,
            peerExpiry: 60,
            removalDebounce: 0.5,
            healthyPongAge: 3.0,
            tickInterval: 0.05,
            usesDiscovery: false,
            bindsListener: true,
            transportStack: .bsdSocket
        )
        let engineA = Harness.makeEngine(selfID: "bsd-aaa", name: "BocanBSDA", config: bsdConfig, store: storeA)
        let engineB = Harness.makeEngine(selfID: "bsd-zzz", name: "BocanBSDB", config: bsdConfig, store: storeB)
        try await engineA.start()
        try await engineB.start()

        let portB = try #require(await engineB.listenerPort())
        #expect(await engineB.usingFallbackForTesting())
        try await engineA.connectManual(host: "127.0.0.1", port: portB)

        await Self.assertSessionEstablished(
            engineA: engineA,
            engineB: engineB,
            peerAID: "bsd-aaa",
            peerBID: "bsd-zzz",
            within: 10
        )

        // The goodbye leg over real sockets.
        await engineA.stop()
        await Self.assertGoodbyeWithoutReconnect(engineB: engineB, storeB: storeB, peerAID: "bsd-aaa")
        await engineB.stop()

        if ProcessInfo.processInfo.environment["PRESENCE_DUMP_LOGS"] != nil {
            let aLines = storeA.snapshot().map { entry in "A \(entry.message)" }
            let bLines = storeB.snapshot().map { entry in "B \(entry.message)" }
            try? (aLines + bLines).joined(separator: "\n").write(
                toFile: "/tmp/presence-loopback.log", atomically: true, encoding: .utf8
            )
        }
    }

    /// The NW stack (primary on healthy macOS builds): binds, accepts, dials
    /// and frames over Network.framework. Where the NW listen path is broken
    /// (macOS 27.2, ADR-097 amendment) this records a known issue instead of
    /// failing the suite; the BSD test above carries real-socket coverage
    /// everywhere.
    @Test
    func networkListenerLoopbackWhenBindable() async throws {
        guard await Self.listenerBindable() else {
            withKnownIssue {
                Issue.record(
                    """
                    NWListener cannot bind in this environment (macOS 27.2 NW listen \
                    path breakage, ADR-097 amendment). The NW stack runs on healthy \
                    macOS builds; real-socket coverage here is carried by \
                    listenerLoopbackOverBSDSockets.
                    """
                )
            }
            return
        }

        let engineA = Harness.makeEngine(selfID: "sock-aaa", name: "BocanSockA", config: Self.socketConfig)
        let engineB = Harness.makeEngine(selfID: "sock-zzz", name: "BocanSockB", config: Self.socketConfig)
        try await engineA.start()
        try await engineB.start()

        let portB = try #require(await engineB.listenerPort())
        try await engineA.connectManual(host: "127.0.0.1", port: portB)

        await Self.assertSessionEstablished(
            engineA: engineA,
            engineB: engineB,
            peerAID: "sock-aaa",
            peerBID: "sock-zzz",
            within: 8
        )

        await engineA.stop()
        await engineB.stop()
    }

    static func listenerBindable() async -> Bool {
        let queue = DispatchQueue(label: "presence.test.bindprobe")
        let listener = try? NWListener(using: NWParameters.tcp, on: .any)
        guard let listener else { return false }
        let outcome = Mutex<String>("pending")
        let resumed = Mutex<Bool>(false)
        listener.stateUpdateHandler = { state in
            let claim = {
                resumed.withLock { was -> Bool in
                    let already = was
                    was = true
                    return !already
                }
            }
            switch state {
            case .ready:
                if claim() { outcome.withLock { $0 = "ready" } }

            case .failed:
                if claim() { outcome.withLock { $0 = "failed" } }

            default:
                break
            }
        }
        listener.start(queue: queue)
        try? await Task.sleep(nanoseconds: 500_000_000)
        listener.cancel()
        return outcome.withLock { $0 } == "ready"
    }
}
