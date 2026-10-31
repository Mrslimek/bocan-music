import Foundation
import Network
import Synchronization

// MARK: - Connection lifecycle

extension PresenceEngine {
    /// Wraps an inbound socket (either stack): a provisional callee
    /// connection that becomes a peer when its hello arrives.
    func acceptInbound(_ transport: WSTransport) async {
        guard self.running else {
            transport.cancel()
            return
        }
        await self.registerConnection(
            role: .callee,
            socket: transport,
            expectedPeerID: nil,
            ownerKey: "pending:\(UUID())",
            pending: true
        )
        self.log.debug("presence.connect_attempt", ["peer": "pending", "addr": "-", "via": "inbound"])
    }

    /// Builds the connection actor, wires its event sink through the engine's
    /// owner table, and starts it.
    func registerConnection(
        role: PeerConnection.Role,
        socket: WSTransport,
        expectedPeerID: String?,
        ownerKey: String,
        pending: Bool
    ) async {
        // The event sink needs the connection id, which exists only after the
        // actor is built; a box hands it over before `start()`, so no event can
        // arrive unattributed.
        let idBox = Mutex<UUID?>(nil)
        let identity = self.identity
        let sink: @Sendable (PeerConnectionEvent) -> Void = { [weak self] event in
            guard let self, let connID = idBox.withLock({ $0 }) else { return }
            Task { await self.handleConnEvent(event, connID: connID) }
        }
        let connection = PeerConnection(
            role: role,
            transport: socket,
            config: self.config,
            selfID: self.identity.id,
            selfName: { identity.name() },
            appVersion: self.appVersion,
            expectedPeerID: expectedPeerID,
            onEvent: sink
        )
        idBox.withLock { $0 = connection.connID }
        if pending {
            self.pendingInbound[connection.connID] = connection
        } else {
            self.connections[ownerKey] = connection
        }
        self.connOwner[connection.connID] = ownerKey
        await connection.start()
    }

    /// Starts a caller socket toward `endpoint` (NW stack) or `hostPort`
    /// (BSD stack).
    func dial(peerID: String, endpoint: NWEndpoint?, hostPort: PresenceHostPort?, expectedPeerID: String?) async {
        guard self.connections[peerID] == nil else { return }
        let socket: WSTransport
        switch self.discoveryStack {
        case .networkFramework:
            guard let endpoint else { return }
            socket = NWWSSocket(endpoint: endpoint, parameters: WSParameters.make(), queue: self.socketQueue)

        case .bsdSocket:
            guard let hostPort else { return }
            guard let client = BSDWSSocket.client(host: hostPort.host, port: hostPort.port) else {
                self.log.debug("presence.connect_failed", ["peer": peerID, "reason": "dial refused"])
                return
            }
            socket = client

        case .automatic:
            return // resolved at start; never dials
        }
        await self.registerConnection(role: .caller, socket: socket, expectedPeerID: expectedPeerID, ownerKey: peerID, pending: false)
    }

    // MARK: Connection events

    func handleConnEvent(_ event: PeerConnectionEvent, connID: UUID) async {
        guard let owner = self.connOwner[connID] else { return }
        switch event {
        case .handshakeSent:
            self.log.debug("presence.handshake_sent", ["peer": owner])

        case let .handshakeCompletedCallee(peerID, info):
            await self.completeCalleeHandshake(connID: connID, peerID: peerID, info: info)

        case let .handshakeCompletedCaller(peerID, peerName, _, _):
            await self.completeCallerHandshake(connID: connID, realPeerID: peerID, peerName: peerName, owner: owner)

        case .pingSent:
            self.log.debug("presence.ping_sent", ["peer": owner])

        case .pingReceived:
            self.log.debug("presence.ping_recv", ["peer": owner])

        case let .pong(rttMs, localDeltaMs):
            self.recordRtt(owner: owner, rttMs: rttMs, localDeltaMs: localDeltaMs)

        case .unknownPong:
            self.log.debug("presence.message_unknown", ["peer": owner, "reason": "pong with unknown replyTo"])

        case let .message(message, envelope):
            await self.routeMessage(message, envelope: envelope, owner: owner)

        case let .unknownType(envelope):
            self.log.debug("presence.message_unknown", ["peer": owner, "type": envelope.type])

        case let .malformed(reason, type):
            self.log.debug("presence.message_malformed", ["peer": owner, "type": type ?? "-", "reason": reason])

        case let .closed(code, reason, cause):
            await self.handleClosed(connID: connID, owner: owner, code: code, reason: reason, cause: cause)
        }
    }

    private func recordRtt(owner: String, rttMs: Double, localDeltaMs: Double) {
        if var record = self.peers[owner] {
            record.lastRttMs = rttMs
            self.peers[owner] = record
        }
        self.log.debug("presence.pong_recv", [
            "peer": owner,
            "rttMs": String(format: "%.0f", rttMs),
            "localDeltaMs": String(format: "%.0f", localDeltaMs),
        ])
        self.publishSnapshot()
    }

    // MARK: Handshake completion (newest-wins adoption)

    private func completeCalleeHandshake(connID: UUID, peerID: String, info: PresenceHelloInfo) async {
        guard let connection = self.pendingInbound.removeValue(forKey: connID) else { return }
        self.adopt(peerID: peerID, connection: connection, owner: connID)
        self.log.debug("presence.connect_ok", [
            "peer": peerID,
            "name": info.name,
            "role": "callee",
        ])
        await self.finishHandshake(peerID: peerID, name: info.name, connection: connection)
    }

    private func completeCallerHandshake(connID: UUID, realPeerID: String, peerName: String, owner: String) async {
        guard let connection = self.connections.removeValue(forKey: owner) else { return }
        if realPeerID != owner {
            // Manual dial adopted its real id: move the record, drop the
            // provisional one.
            self.connOwner[connID] = realPeerID
            if var existing = self.peers[realPeerID] {
                existing.name = peerName
                existing.connection = .connecting
                self.peers[realPeerID] = existing
            } else {
                var record = PeerRecord(id: realPeerID, name: peerName, endpoint: nil, lastAnnounce: Date())
                record.discovery = .inboundOnly
                record.isManual = true
                record.connection = .connecting
                self.peers[realPeerID] = record
            }
            self.peers.removeValue(forKey: owner)
        }
        self.adopt(peerID: realPeerID, connection: connection, owner: connID)
        self.log.debug("presence.connect_ok", [
            "peer": realPeerID,
            "name": peerName,
            "role": "caller",
        ])
        await self.finishHandshake(peerID: realPeerID, name: peerName, connection: connection)
    }

    /// Newest-wins (contract section 3): at most one connection per peer id;
    /// the newest socket wins and the old one is closed with 4003.
    private func adopt(peerID: String, connection: PeerConnection, owner connID: UUID) {
        if let existing = self.connections[peerID], existing.connID != connID {
            self.connOwner.removeValue(forKey: existing.connID)
            self.log.debug("presence.disconnect", [
                "peer": peerID,
                "reason": "superseded by newer connection (4003)",
            ])
            Task { await existing.supersede() }
        }
        self.connections[peerID] = connection
        self.connOwner[connID] = peerID
    }

    /// Shared post-handshake bookkeeping: fresh session, backoff reset, and the
    /// immediate state snapshot both ways (contract section 3).
    private func finishHandshake(peerID: String, name: String, connection: PeerConnection) async {
        // The counter starts at 1 each app run (contract section 6): the first
        // send announces the initial (stopped) state as seq 1.
        if self.ownState.seq == 0 {
            self.ownState = PresencePlaybackState(track: "", status: .stopped, positionSec: 0, seq: 1)
        }
        if var record = self.peers[peerID] {
            record.name = name
            record.connection = .connected
            record.backoffIndex = 0
            record.suppressReconnect = false
            record.nextDialAt = nil
            record.pendingRemovalSince = nil
            self.peers[peerID] = record
        } else {
            var record = PeerRecord(id: peerID, name: name, endpoint: nil, lastAnnounce: Date())
            record.discovery = .inboundOnly
            record.connection = .connected
            self.peers[peerID] = record
        }
        // Session view: the stint owner's socket is back; the peer's own
        // state updates then advance or resolve the stint.
        self.sessionPeerReconnected(peerID: peerID)

        await connection.sendState(self.ownState)
        if let state = self.ownStateAsSent() {
            self.log.debug("presence.state_sent", [
                "peer": peerID,
                "track": state.track,
                "status": state.status.rawValue,
                "pos": String(format: "%.1f", state.positionSec),
                "seq": String(state.seq),
                "note": "post-handshake snapshot",
            ])
        }
        self.publishSnapshot()
    }

    // MARK: Close / reconnect

    private func handleClosed(connID: UUID, owner: String, code: UInt16, reason: String, cause: DisconnectCause) async {
        self.connections.removeValue(forKey: owner)
        self.pendingInbound.removeValue(forKey: connID)
        self.connOwner.removeValue(forKey: connID)
        self.log.debug("presence.disconnect", [
            "peer": owner,
            "code": String(code),
            "reason": reason,
            "cause": String(describing: cause),
        ])

        // Superseded sockets and shutdown closes never touch peer state.
        guard cause != .superseded, cause != .shutdown else { return }
        guard var record = self.peers[owner] else { return }
        record.connection = .unreachable
        self.peers[owner] = record
        // Session view: a disconnect does NOT end the session - the stint
        // stays visible as last-known, now unreachable.
        self.sessionPeerUnreachable(peerID: owner)

        // Goodbye means gone (contract section 5): no reconnect scheduling.
        guard !record.suppressReconnect, record.discovery != .gone else {
            self.publishSnapshot()
            return
        }
        self.scheduleReconnect(peerID: owner)
        self.publishSnapshot()
    }

    /// The contract ladder: 1.5 -> 30 s with jitter; reset after success;
    /// stops while gone.
    func scheduleReconnect(peerID: String) {
        guard var record = self.peers[peerID], record.endpoint != nil else { return }
        let delay = self.config.backoff.randomDelay(attempt: record.backoffIndex)
        record.backoffIndex += 1
        record.nextDialAt = Date().addingTimeInterval(delay)
        self.peers[peerID] = record
        self.log.debug("presence.reconnect_scheduled", [
            "peer": peerID,
            "attempt": String(record.backoffIndex),
            "delayMs": String(format: "%.0f", delay * 1000),
        ])
    }
}
