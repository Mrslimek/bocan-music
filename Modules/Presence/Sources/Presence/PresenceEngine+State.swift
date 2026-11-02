import Foundation

// MARK: - Receiver rules and message routing

extension PresenceEngine {
    /// Routes a decoded application message for a connected peer: duplicate
    /// detection, announcement refresh, then per-type handling.
    func routeMessage(_ message: PresenceMessage, envelope: PresenceEnvelope, owner: String) async {
        if self.isDuplicate(envelope.id, owner: owner) {
            self.log.debug("presence.message_duplicate", ["peer": owner, "id": String(envelope.id.prefix(8))])
            return
        }
        self.recordMessageID(envelope.id, owner: owner)
        self.refreshAnnouncement(owner: owner)

        switch message {
        case let .stateUpdate(state):
            await self.applyReceivedState(peerID: owner, state: state)

        case let .goodbye(reason):
            self.log.debug("presence.goodbye_recv", ["peer": owner, "reason": reason])
            // Goodbye means gone (contract section 5): the peer shut down or
            // the user closed it; no reconnect follows until it reappears.
            // Session view: a gone stint stays visible as last-known.
            self.sessionPeerGone(peerID: owner)
            if var record = self.peers[owner] {
                record.suppressReconnect = true
                self.peers[owner] = record
            }
            if let connection = self.connections[owner] {
                await connection.closeLocally(code: 1000, reason: "peer said goodbye", cause: .remote)
            }

        case let .test(text):
            self.log.debug("presence.msg_recv", ["peer": owner, "text": text])

        case let .command(command):
            await self.applyInboundCommand(command, owner: owner)

        case let .queue(message):
            self.applyInboundQueue(message, owner: owner)

        case .hello, .helloAck, .ping, .pong:
            break // liveness messages are handled inside the connection actor
        }
    }

    /// Applies an inbound `command` per contract section 6: unknown actions
    /// and the disabled gate log `command_ignored` and are never applied;
    /// `seek` without a position is malformed; applied commands are never
    /// relayed or answered.
    func applyInboundCommand(_ command: PresenceCommand, owner: String) async {
        let peerName = self.peers[owner]?.name ?? owner
        guard let action = PresenceCommandAction(rawValue: command.action) else {
            self.log.debug("presence.command_ignored", [
                "peer": owner,
                "name": peerName,
                "action": command.action,
                "reason": "unsupported",
            ])
            return
        }
        if action == .seek, command.positionSec == nil {
            self.log.debug("presence.message_malformed", [
                "peer": owner,
                "type": "command",
                "reason": "seek without positionSec",
            ])
            return
        }
        guard self.controlEnabled() else {
            self.log.debug("presence.command_ignored", [
                "peer": owner,
                "name": peerName,
                "action": action.rawValue,
                "reason": "disabled",
            ])
            return
        }
        self.log.debug("presence.command_recv", [
            "peer": owner,
            "name": peerName,
            "action": action.rawValue,
            "pos": command.positionSec.map { String(format: "%.1f", $0) } ?? "-",
        ])
        let applied = await self.commandExecutor(action, command.positionSec)
        if !applied {
            self.log.debug("presence.command_ignored", [
                "peer": owner,
                "name": peerName,
                "action": action.rawValue,
                "reason": "unsupported",
            ])
        }
    }

    private func isDuplicate(_ id: String, owner: String) -> Bool {
        self.seenMessageIDs[owner]?.contains(id) == true
    }

    private func recordMessageID(_ id: String, owner: String) {
        var ring = self.seenMessageIDs[owner] ?? []
        ring.append(id)
        if ring.count > 128 {
            ring.removeFirst(ring.count - 128)
        }
        self.seenMessageIDs[owner] = ring
    }

    private func refreshAnnouncement(owner: String) {
        if var record = self.peers[owner] {
            record.lastAnnounce = Date()
            self.peers[owner] = record
        }
    }

    /// Stores the latest arrival per peer, logs `state_conflict` when the
    /// arriving seq does not advance (contract section 6), and fires the
    /// session's peer-became-active callback when a session-capable peer
    /// starts a new playing stint (contract section 8).
    func applyReceivedState(peerID: String, state: PresencePlaybackState) async {
        var previousPlayback: PresencePlaybackState?
        if var record = self.peers[peerID] {
            previousPlayback = record.playback
            if let last = record.lastSeenSeq, state.seq <= last {
                self.log.warning("presence.state_conflict", [
                    "peer": peerID,
                    "seq": String(state.seq),
                    "lastSeq": String(last),
                ])
            }
            record.lastSeenSeq = state.seq
            record.playback = state
            self.peers[peerID] = record
        }
        self.log.debug("presence.state_recv", [
            "peer": peerID,
            "track": state.track,
            "artist": state.artist ?? "-",
            "status": state.status.rawValue,
            "pos": String(format: "%.1f", state.positionSec),
            "seq": String(state.seq),
        ])
        await self.detectPeerBecameActive(peerID: peerID, state: state, previous: previousPlayback)
        // Session view (contract section 8): the stint peer's own state
        // drives the view - a new stint replaces it, same stint advances the
        // last-known position, non-playing resolves the stint to local.
        if case let .remote(stint) = self.session.source, stint.peerID == peerID {
            if state.status == .playing, state.playbackId == stint.lastKnown.playbackId,
               let trackHash = state.trackHash {
                self.sessionPeerState(peerID: peerID, state: state)
                _ = trackHash
            } else if state.status != .playing {
                self.sessionPeerState(peerID: peerID, state: state)
            }
        }
        self.publishSnapshot()
    }

    /// A session-capable peer (trackHash present) that starts playing a new
    /// stint: the handoff signal. A pause-to-resume of the same stint does
    /// not fire; peers without a trackHash never do (section 8 capability).
    private func detectPeerBecameActive(
        peerID: String,
        state: PresencePlaybackState,
        previous: PresencePlaybackState?
    ) async {
        guard state.status == .playing,
              let trackHash = state.trackHash,
              let playbackId = state.playbackId else { return }
        // The stint is unchanged when the id matches the last seen one, even
        // across a pause (contract section 8: a pause-to-resume keeps it); a
        // fresh id is the takeover/track-start signal.
        let sameStint = previous?.playbackId == playbackId
        guard !sameStint else { return }
        let peerName = self.peers[peerID]?.name ?? peerID
        self.log.debug("presence.session.peer_active", [
            "peer": peerID,
            "name": peerName,
            "track": state.track,
            "pos": String(format: "%.1f", state.positionSec),
        ])
        self.sessionPeerBecameActive(peerID: peerID, state: state)
        await self.onPeerBecameActive?(peerID, peerName, trackHash, state.positionSec, playbackId)
    }
}

// MARK: - Own playback state

extension PresenceEngine {
    /// How often a position-only change is re-broadcast while playing. Track
    /// and status changes always broadcast immediately.
    static let positionRefreshInterval: TimeInterval = 10

    /// Applies a playback tap report: discrete changes bump the seq and
    /// broadcast immediately; position-only changes keep the payload fresh and
    /// re-broadcast at most every `positionRefreshInterval` (each broadcast
    /// bumps the seq, so receivers never see a non-advancing seq).
    func applyOwnState(_ incoming: PresencePlaybackState) async {
        let previous = self.ownState
        let now = Date()

        // Shared session (contract section 8): the stint id is fresh on every
        // track start and every takeover, and kept across a pause-to-resume
        // of the same stint. Entering .playing with a different track hash
        // (or entering playing for the first time) starts a new stint.
        if incoming.status == .playing {
            let trackChanged = incoming.trackHash != self.lastStintTrackHash
            if self.ownPlaybackID == nil || trackChanged {
                self.ownPlaybackID = UUID().uuidString.lowercased()
            }
            self.lastStintTrackHash = incoming.trackHash
        }

        // Session view: self starting a local playing stint wins immediately
        // (absorbs any remote stint or in-flight takeover).
        if incoming.status == .playing, self.session.source != .local {
            self.sessionLocalWin()
        }

        var updated = incoming
        updated.playbackId = incoming.status == .playing || previous.status == .playing
            ? self.ownPlaybackID
            : nil
        let discreteChange = incoming.track != previous.track
            || incoming.artist != previous.artist
            || incoming.status != previous.status
            || updated.trackHash != previous.trackHash
            || updated.playbackId != previous.playbackId

        if discreteChange || previous.seq == 0 {
            updated.seq = previous.seq + 1
            self.ownState = updated
            self.lastPositionBroadcastAt = now
            await self.broadcastState()
            return
        }

        updated.seq = previous.seq
        self.ownState = updated
        let positionMoved = incoming.positionSec != previous.positionSec
        if positionMoved, now.timeIntervalSince(self.lastPositionBroadcastAt) >= Self.positionRefreshInterval {
            updated.seq = previous.seq + 1
            self.ownState = updated
            self.lastPositionBroadcastAt = now
            await self.broadcastState()
        }
    }

    /// Sends the current own state to every connected peer.
    func broadcastState() async {
        let connected = Array(self.connections.values)
        guard !connected.isEmpty else { return }
        for connection in connected {
            await connection.sendState(self.ownState)
        }
        if let state = self.ownStateAsSent() {
            self.log.debug("presence.state_sent", [
                "to": String(connected.count),
                "track": state.track,
                "status": state.status.rawValue,
                "pos": String(format: "%.1f", state.positionSec),
                "seq": String(state.seq),
            ])
        }
    }

    /// The payload as it would be sent (seq assigned), for logging.
    func ownStateAsSent() -> PresencePlaybackState? {
        guard self.ownState.seq > 0 else { return nil }
        return self.ownState
    }
}

// MARK: - Discovery events

extension PresenceEngine {
    func startBrowsing() async {
        let events: @Sendable (PresenceDiscoveryEvent) -> Void = { [weak self] event in
            guard let self else { return }
            Task { await self.handleDiscoveryEvent(event) }
        }
        switch self.discoveryStack {
        case .networkFramework:
            let browser = PresenceBrowser(
                serviceType: self.config.serviceType,
                selfID: self.identity.id,
                protocolVersion: self.config.protocolVersion,
                onEvent: events
            )
            await browser.start(queue: self.socketQueue)
            self.browser = browser

        case .bsdSocket:
            // NetService browsing also browses our own service type, which is
            // what raises the Local Network prompt on the fallback stack.
            let browser = NetServicePresence()
            browser.onEvent = events
            browser.startBrowsing()
            self.netServiceBrowser = browser

        case .automatic:
            return // resolved at start; never browses
        }
    }

    func makeRebrowseTask() -> Task<Void, Never> {
        let interval = self.config.rebrowseInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, await self.isRunning else { return }
                await self.restartBrowse()
            }
        }
    }

    func restartBrowse() async {
        switch self.discoveryStack {
        case .networkFramework:
            await self.browser?.restart()

        case .bsdSocket:
            self.netServiceBrowser?.restartBrowsing()

        case .automatic:
            return
        }
    }

    func handleDiscoveryEvent(_ event: PresenceDiscoveryEvent) async {
        switch event {
        case let .found(announcement):
            self.handleFound(announcement)

        case let .removed(peerID):
            await self.handleRemovalHint(peerID: peerID)

        case let .failed(detail):
            self.log.error("presence.discovery.failed", ["error": detail])
        }
    }

    /// A (re-)announcement: refresh the peer, revive gone peers, and apply the
    /// tie-break for new ones.
    func handleFound(_ announcement: PresenceAnnouncement) {
        let now = Date()
        if var record = self.peers[announcement.peerID] {
            record.endpoint = announcement.endpoint
            record.hostPort = Self.hostPort(from: announcement)
            record.name = announcement.name
            record.lastAnnounce = now
            record.pendingRemovalSince = nil
            let wasGone = record.discovery == .gone
            record.discovery = record.discovery == .inboundOnly ? .inboundOnly : .discovered
            self.peers[announcement.peerID] = record
            if wasGone {
                // Reappeared: resume the schedule from scratch (contract section 5).
                record.backoffIndex = 0
                record.suppressReconnect = false
                record.nextDialAt = now
                self.peers[announcement.peerID] = record
                self.log.debug("presence.peer_found", ["peer": announcement.peerID, "name": announcement.name, "note": "reappeared"])
            } else if record.connection == .unreachable, self.connections[announcement.peerID] == nil {
                record.nextDialAt = now
                self.peers[announcement.peerID] = record
            } else {
                self.log.debug("presence.peer_found", ["peer": announcement.peerID, "name": announcement.name, "note": "re-announced"])
            }
            self.publishSnapshot()
            return
        }

        var record = PeerRecord(
            id: announcement.peerID,
            name: announcement.name,
            endpoint: announcement.endpoint,
            lastAnnounce: now
        )
        record.hostPort = Self.hostPort(from: announcement)
        if Self.shouldDial(selfID: self.identity.id, peerID: announcement.peerID) {
            record.nextDialAt = now
        }
        self.peers[announcement.peerID] = record
        self.log.debug("presence.peer_found", [
            "peer": announcement.peerID,
            "name": announcement.name,
            "dialer": record.nextDialAt == nil ? "peer" : "self",
        ])
        self.publishSnapshot()
    }

    /// A removal hint: healthy connected sockets ignore it; everyone else gets
    /// the debounced gone path (`applyExpiredRemovals`).
    func handleRemovalHint(peerID: String) async {
        guard var record = self.peers[peerID] else { return }
        if let connection = self.connections[peerID] {
            // The healthy-socket guard: a CONNECTED socket with fresh pongs is
            // never marked gone from a discovery hint alone.
            let healthy = await connection.isHealthy(maxPongAge: self.config.healthyPongAge, now: Date())
            if healthy {
                self.log.debug("presence.dns_hint_ignored", ["peer": peerID, "reason": "socket_healthy"])
                return
            }
        }
        if record.pendingRemovalSince == nil {
            record.pendingRemovalSince = Date()
            self.peers[peerID] = record
        }
    }
}

// MARK: - Directory publishing

extension PresenceEngine {
    static func hostPort(from announcement: PresenceAnnouncement) -> PresenceHostPort? {
        guard let host = announcement.host, let port = announcement.port else { return nil }
        return PresenceHostPort(host: host, port: port)
    }

    func publishSnapshot() {
        self.directory.publish(self.buildSnapshots())
    }

    func buildSnapshots() -> [PeerSnapshot] {
        self.peers.keys.sorted().compactMap { peerID -> PeerSnapshot? in
            guard let record = self.peers[peerID] else { return nil }
            let role: String? = if let connection = self.connections[peerID] {
                connection.role == .caller ? "caller" : "callee"
            } else {
                nil
            }
            return PeerSnapshot(
                id: record.id,
                name: record.name,
                discovery: record.discovery,
                connection: record.connection,
                playback: record.playback,
                rttMs: record.lastRttMs,
                role: role
            )
        }
    }
}
