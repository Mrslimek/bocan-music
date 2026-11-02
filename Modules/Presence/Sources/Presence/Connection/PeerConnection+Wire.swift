import Foundation

// MARK: - Incoming frame routing

extension PeerConnection {
    func onText(_ text: String) {
        guard let frame = WireCodec.decode(text) else {
            self.onEvent(.malformed(reason: "undecodable frame", type: nil))
            return
        }
        switch frame {
        case let .message(message, envelope):
            self.route(message: message, envelope: envelope)

        case let .unknownType(envelope):
            self.onEvent(.unknownType(envelope))

        case let .malformed(reason, type):
            self.onEvent(.malformed(reason: reason, type: type))
        }
    }

    private func route(message: PresenceMessage, envelope: PresenceEnvelope) {
        switch message {
        case let .hello(info):
            self.handleHello(info, envelope: envelope)

        case let .helloAck(info):
            self.handleHelloAck(info, envelope: envelope)

        case .ping:
            self.answerPong(replyTo: envelope.id)
            self.onEvent(.pingReceived)

        case .pong:
            self.recordPong(envelope: envelope)

        case let .stateUpdate(state):
            self.onEvent(.message(.stateUpdate(state), envelope: envelope))

        case let .test(text):
            self.onEvent(.message(.test(text: text), envelope: envelope))

        case let .command(command):
            self.onEvent(.message(.command(command), envelope: envelope))

        case let .queue(message):
            self.onEvent(.message(.queue(message), envelope: envelope))

        case let .goodbye(reason):
            self.onEvent(.message(.goodbye(reason: reason), envelope: envelope))
        }
    }

    // MARK: Handshake

    private func handleHello(_ info: PresenceHelloInfo, envelope: PresenceEnvelope) {
        guard self.role == .callee else {
            // Hello on a caller socket is malformed per the MVP reference; log
            // and keep the connection.
            self.onEvent(.malformed(reason: "hello on caller socket", type: "hello"))
            return
        }
        guard self.phase == .awaitingHello else {
            self.onEvent(.unknownType(envelope))
            return
        }
        // Fresh keepalive budget for the new transport (the MVP's defect 11):
        // outstanding pings belong to dead sockets, and the watchdog keys on
        // the last pong, so without this a fresh handshake could inherit a
        // stale budget and be judged dead on its first tick.
        self.completeHandshake()
        let ackInfo = PresenceHelloInfo(name: self.selfName(), platform: "macos", appVersion: self.appVersion)
        self.send(.helloAck(ackInfo), replyTo: envelope.id)
        self.onEvent(.handshakeCompletedCallee(peerID: envelope.from, info: info))
    }

    private func handleHelloAck(_ info: PresenceHelloInfo, envelope: PresenceEnvelope) {
        guard self.role == .caller else {
            self.onEvent(.unknownType(envelope))
            return
        }
        guard self.phase == .awaitingHelloAck else {
            self.onEvent(.unknownType(envelope))
            return
        }
        guard envelope.replyTo == self.helloSentID else {
            self.onEvent(.malformed(reason: "hello_ack replyTo mismatch", type: "hello_ack"))
            return
        }
        if let expected = self.expectedPeerID, envelope.from != expected {
            self.onEvent(.malformed(reason: "hello_ack from \(envelope.from) != expected \(expected)", type: "hello_ack"))
            return
        }
        self.completeHandshake()
        self.onEvent(.handshakeCompletedCaller(
            peerID: envelope.from,
            peerName: info.name,
            platform: info.platform,
            appVersion: info.appVersion
        ))
    }

    /// Resets every liveness counter for the transport that just finished its
    /// handshake. Both roles run through here (defects 2/10/11 guard).
    private func completeHandshake() {
        self.outstandingPings.removeAll()
        self.lastPongAt = Date()
        self.lastPingSentAt = Date()
        self.ackDeadline = nil
        self.helloDeadline = nil
        self.dialDeadline = nil
        self.phase = .ready
    }

    // MARK: Keepalive

    func sendPing(now: Date) {
        let envelope = WireCodec.envelope(from: self.selfID, nowMs: Self.nowMs())
        self.outstandingPings[envelope.id] = (peerTS: envelope.ts, localMs: Self.nowMs())
        self.lastPingSentAt = now
        guard let text = try? WireCodec.encode(.ping, envelope: envelope) else { return }
        self.transport.send(text)
        self.onEvent(.pingSent)
    }

    private func answerPong(replyTo: String) {
        let envelope = WireCodec.envelope(from: self.selfID, nowMs: Self.nowMs(), replyTo: replyTo)
        guard let text = try? WireCodec.encode(.pong, envelope: envelope) else { return }
        self.transport.send(text)
    }

    private func recordPong(envelope: PresenceEnvelope) {
        guard let replyTo = envelope.replyTo, let sent = self.outstandingPings.removeValue(forKey: replyTo) else {
            self.onEvent(.unknownPong)
            return
        }
        // Contract formula: pong.ts - ping.ts. Clocks are comparable only
        // within one peer, so the local send->receive delta is logged alongside.
        let rtt = envelope.ts - sent.peerTS
        let localDelta = Self.nowMs() - sent.localMs
        self.lastPongAt = Date()
        self.onEvent(.pong(rttMs: rtt, localDeltaMs: localDelta))
    }

    // MARK: Sending

    func send(_ message: PresenceMessage, replyTo: String?) {
        let envelope = WireCodec.envelope(from: self.selfID, nowMs: Self.nowMs(), replyTo: replyTo)
        guard let text = try? WireCodec.encode(message, envelope: envelope) else { return }
        self.transport.send(text)
    }
}
