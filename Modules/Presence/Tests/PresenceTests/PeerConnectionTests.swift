import Foundation
import Testing
@testable import Presence

// MARK: - Keepalive watchdog, teardown latch, handshake budget

/// The defect guards from the reference MVP's measured defects 2/10/11:
/// the watchdog keys on the last RECEIVED pong, all per-connection liveness
/// state dies with the transport, and the teardown decision is one-shot.
struct PeerConnectionTests {
    private func makeCaller(
        transport: MockWSTransport,
        collector: EventCollector,
        config: PresenceConfig = Harness.testConfig,
        expectedPeerID: String? = "zzz"
    ) -> PeerConnection {
        let sink: @Sendable (PeerConnectionEvent) -> Void = { collector.append($0) }
        return PeerConnection(
            role: .caller,
            transport: transport,
            config: config,
            selfID: "aaa",
            selfName: { "A" },
            appVersion: "test",
            expectedPeerID: expectedPeerID,
            onEvent: sink
        )
    }

    /// Starts a caller, waits for its hello on the wire (so tests never race
    /// the ordered event pump), then answers with a valid hello_ack.
    private func handshakeCaller(
        transport: MockWSTransport,
        collector: EventCollector,
        config: PresenceConfig = Harness.testConfig,
        ackFrom peerID: String = "zzz"
    ) async -> PeerConnection {
        let connection = self.makeCaller(transport: transport, collector: collector, config: config)
        await connection.start()
        await waitUntil { transport.sentObject(at: 0)?["type"] as? String == "hello" }
        let helloID = transport.sentObject(at: 0)?["id"] as? String ?? ""
        transport.deliver(
            "{\"v\":1,\"type\":\"hello_ack\",\"id\":\"h1\",\"from\":\"\(peerID)\",\"ts\":1," +
                "\"replyTo\":\"\(helloID)\",\"name\":\"B\",\"platform\":\"macos\",\"appVersion\":\"t\"}"
        )
        // Wait for the handshake to actually complete on the actor, so tests
        // never tick against a connection that is still mid-handshake.
        let completed = await waitUntil(within: 3) {
            collector.all.contains { event in
                if case .handshakeCompletedCaller = event {
                    return true
                }
                return false
            }
        }
        #expect(completed)
        return connection
    }

    @Test
    func callerSendsHelloOnOpenAndArmsAckDeadline() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()

        let sentHello = await waitUntil { transport.sentObject(at: 0)?["type"] as? String == "hello" }
        #expect(sentHello)
        #expect(collector.all.contains { event in
            if case .handshakeSent = event {
                return true
            }
            return false
        })
    }

    @Test
    func watchdogFiresOnceOnPongSilenceAndLatches() async throws {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = await self.handshakeCaller(transport: transport, collector: collector)

        // Drive well past the pong budget: exactly one keepalive close.
        let start = Date()
        for offset in stride(from: 0.0, through: 2.5, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        let closed = collector.closed
        guard case let .closed(code, reason, cause)? = closed else {
            Issue.record("expected a closed event, got \(collector.all.count) events")
            return
        }
        #expect(cause == .keepaliveTimeout)
        #expect(code == 1000)
        #expect(reason == "keepalive timeout")
        #expect(collector.closedCount == 1)
        #expect(transport.closeSent?.code == 1000)
        // One-shot: ticks after the decision are no-ops.
        await connection.tick(now: start.addingTimeInterval(10))
        await connection.tick(now: start.addingTimeInterval(11))
        #expect(collector.closedCount == 1)
    }

    @Test
    func freshHandshakeIsNotJudgedDeadOnEarlyTicks() async {
        // The regression behind the MVP's defect 11: a fresh session judged
        // dead within one tick because stale unanswered pings from a previous
        // transport survived the handshake. In this architecture the liveness
        // state lives in the connection actor, so a fresh handshake starts
        // with an empty outstanding set and a pong budget measured from now.
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = await self.handshakeCaller(transport: transport, collector: collector)

        let handshakeDone = await waitUntil {
            collector.all.contains { event in
                if case .handshakeCompletedCaller = event {
                    return true
                }
                return false
            }
        }
        #expect(handshakeDone)

        // Tick across most of the pong budget: no keepalive close may fire
        // before the budget actually elapses.
        let start = Date()
        for offset in stride(from: 0.0, through: 0.7, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
        }
        #expect(collector.closed == nil)
    }

    @Test
    func pongWithinBudgetKeepsConnectionAliveAndReportsRTT() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = await self.handshakeCaller(transport: transport, collector: collector)

        let start = Date()
        var pingID: String?
        for offset in stride(from: 0.0, through: 1.5, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
            if pingID == nil, let object = transport.sentObject(at: 1), object["type"] as? String == "ping" {
                let pingID = object["id"] as? String ?? ""
                let pingTS = object["ts"] as? Double ?? 0
                // Peer answers 250 ms later by its own clock.
                transport.deliver("{\"v\":1,\"type\":\"pong\",\"id\":\"p1\",\"from\":\"zzz\",\"ts\":\(pingTS + 250)," +
                    "\"replyTo\":\"\(pingID)\"}")
            }
        }
        let pongSeen = await waitUntil { !collector.pongEvents.isEmpty }
        #expect(pongSeen)
        // Contract formula: pong.ts - ping.ts.
        #expect(abs((collector.pongEvents.first ?? 0) - 250) < 1)

        // Still alive: the last pong keeps refreshing the budget.
        let closedBefore = collector.closedCount
        for offset in stride(from: 1.6, through: 2.4, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
            if let object = transport.sent.last.flatMap({ $0.data(using: .utf8) }),
               let parsed = try? JSONSerialization.jsonObject(with: object) as? [String: Any],
               parsed["type"] as? String == "ping",
               let id = parsed["id"] as? String,
               let ts = parsed["ts"] as? Double {
                transport.deliver("{\"v\":1,\"type\":\"pong\",\"id\":\"p\",\"from\":\"zzz\",\"ts\":\(ts + 5),\"replyTo\":\"\(id)\"}")
            }
        }
        #expect(collector.closedCount == closedBefore)
    }

    @Test
    func unknownPongIsReportedNotDestructive() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()
        transport.deliver("{\"v\":1,\"type\":\"pong\",\"id\":\"p\",\"from\":\"zzz\",\"ts\":9,\"replyTo\":\"nope\"}")
        let seen = await waitUntil {
            collector.all.contains { event in
                if case .unknownPong = event {
                    return true
                }
                return false
            }
        }
        #expect(seen)
        #expect(collector.closed == nil)
    }

    @Test
    func dialTimeoutCancelsWithoutCloseFrame() async {
        let transport = MockWSTransport()
        transport.opensOnStart = false // dead peer: the socket never opens
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()

        let start = Date()
        for offset in stride(from: 0.0, through: 1.0, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
        }
        let fired = await waitUntil { collector.closed != nil }
        #expect(fired)
        guard case let .closed(code, reason, cause)? = collector.closed else { return }
        #expect(cause == .dialTimeout)
        #expect(code == 1011)
        #expect(reason == "connect timeout")
        #expect(transport.cancelled)
        #expect(transport.closeSent == nil)
    }

    @Test
    func calleeHelloTimeoutCloses4002() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let sink: @Sendable (PeerConnectionEvent) -> Void = { collector.append($0) }
        let connection = PeerConnection(
            role: .callee,
            transport: transport,
            config: Harness.testConfig,
            selfID: "aaa",
            selfName: { "A" },
            appVersion: "test",
            expectedPeerID: nil,
            onEvent: sink
        )
        await connection.start()

        let start = Date()
        for offset in stride(from: 0.0, through: 1.0, by: 0.1) {
            await connection.tick(now: start.addingTimeInterval(offset))
        }
        let fired = await waitUntil { collector.closed != nil }
        #expect(fired)
        guard case let .closed(code, _, cause)? = collector.closed else { return }
        #expect(cause == .handshakeTimeout)
        #expect(code == 4002)
    }

    @Test
    func calleeAnswersHelloAndCompletesHandshake() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let sink: @Sendable (PeerConnectionEvent) -> Void = { collector.append($0) }
        let connection = PeerConnection(
            role: .callee,
            transport: transport,
            config: Harness.testConfig,
            selfID: "aaa",
            selfName: { "A" },
            appVersion: "test",
            expectedPeerID: nil,
            onEvent: sink
        )
        await connection.start()

        transport.deliver("{\"v\":1,\"type\":\"hello\",\"id\":\"h\",\"from\":\"zzz\",\"ts\":1," +
            "\"name\":\"B\",\"platform\":\"macos\",\"appVersion\":\"t\"}")
        let acked = await waitUntil { transport.sentObject(at: 0)?["type"] as? String == "hello_ack" }
        #expect(acked)
        #expect(transport.sentObject(at: 0)?["replyTo"] as? String == "h")
        let completed = await waitUntil {
            collector.all.contains { event in
                if case .handshakeCompletedCallee = event {
                    return true
                }
                return false
            }
        }
        #expect(completed)
    }

    @Test
    func callerRejectsHelloAckFromWrongPeer() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()
        // An ack answering our hello but from the wrong peer id: rejected, and
        // the handshake stays open (malformed, not hostile).
        await waitUntil { transport.sentObject(at: 0)?["type"] as? String == "hello" }
        let helloID = transport.sentObject(at: 0)?["id"] as? String ?? ""
        transport.deliver("{\"v\":1,\"type\":\"hello_ack\",\"id\":\"h2\",\"from\":\"mmm\",\"ts\":1," +
            "\"replyTo\":\"\(helloID)\",\"name\":\"Impostor\",\"platform\":\"macos\",\"appVersion\":\"t\"}")
        // Receiver rules: malformed ack is logged and ignored, connection kept.
        let rejected = await waitUntil(within: 3) {
            collector.all.contains { event in
                if case .malformed = event {
                    return true
                }
                return false
            }
        }
        #expect(rejected)
        #expect(collector.closed == nil)
    }

    @Test
    func supersedeClosesExactlyOnceWith4003() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()
        await connection.supersede()
        await connection.supersede()
        let fired = await waitUntil { collector.closed != nil }
        #expect(fired)
        guard case let .closed(code, reason, cause)? = collector.closed else { return }
        #expect(code == 4003)
        #expect(reason == "superseded by newer connection")
        #expect(cause == .superseded)
        #expect(collector.closedCount == 1)
    }

    @Test
    func lateSocketDeathAfterTeardownEmitsNoSecondClose() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()
        await connection.supersede()
        // The superseded socket's late remote close must not produce a second
        // death event.
        transport.deliverRemoteClose(code: 1000, reason: "superseded by newer connection")
        transport.emit(.failed("cancelled"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(collector.closedCount == 1)
    }

    @Test
    func goodbyeSendsFrameThenCloses1000() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = self.makeCaller(transport: transport, collector: collector)
        await connection.start()
        await connection.goodbye(reason: "app_shutdown")
        let fired = await waitUntil { collector.closed != nil }
        #expect(fired)
        let goodbyeOnWire = transport.sent.contains { text in
            text.contains("\"type\":\"goodbye\"") && text.contains("app_shutdown")
        }
        #expect(goodbyeOnWire)
        guard case let .closed(code, _, cause)? = collector.closed else { return }
        #expect(code == 1000)
        #expect(cause == .shutdown)
    }

    @Test
    func healthRequiresFreshPong() async {
        let transport = MockWSTransport()
        let collector = EventCollector()
        let connection = await self.handshakeCaller(transport: transport, collector: collector)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Freshly handshook: healthy inside the window...
        let now = Date()
        let healthyNow = await connection.isHealthy(maxPongAge: 15, now: now)
        #expect(healthyNow)
        // ...but not when the last pong is older than the window.
        let healthyStale = await connection.isHealthy(maxPongAge: 0, now: now.addingTimeInterval(1))
        #expect(!healthyStale)
    }
}
