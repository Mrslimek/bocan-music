import Foundation
import Network

// MARK: - Housekeeping tick

extension PresenceEngine {
    func runTicks() async {
        while !Task.isCancelled {
            await self.runOneTick(Date())
            // Sanctioned idiom: a cancelled sleep exits cleanly and the loop
            // re-checks cancellation before the next pass.
            try? await Task.sleep(nanoseconds: UInt64(self.config.tickInterval * 1_000_000_000))
        }
    }

    func runOneTick(_ now: Date) async {
        await self.tickConnections(now)
        await self.dialDuePeers(now)
        self.applyExpiredRemovals(now)
        self.expireStalePeers(now)
        await self.evaluateSessionConflict(now)
        self.publishSnapshot()
    }

    /// The single-active invariant (contract section 8), observed every tick
    /// among {self + connected session-capable peers}. Two-or-more playing
    /// devices overlapping longer than the handoff grace emit one local
    /// `session_conflict` naming the device ids; the engine never
    /// auto-resolves - the event resets only when the overlap ends.
    private func evaluateSessionConflict(_ now: Date) async {
        var parties: [String] = []
        if self.ownState.status == .playing, self.ownState.trackHash != nil {
            parties.append(self.identity.id)
        }
        for (peerID, record) in self.peers
        where record.playback?.status == .playing
            && record.playback?.trackHash != nil
            && self.connections[peerID] != nil {
            parties.append(peerID)
        }

        guard parties.count >= 2 else {
            self.conflictSince = nil
            self.conflictFired = false
            if self.session.conflict != nil {
                self.sessionConflictCleared()
            }
            return
        }
        if self.conflictSince == nil {
            self.conflictSince = now
        }
        guard !self.conflictFired,
              let since = self.conflictSince,
              now.timeIntervalSince(since) >= self.config.sessionConflictGrace else { return }
        self.conflictFired = true
        let names = parties.map { peerID in
            peerID == self.identity.id ? self.identity.name() : (self.peers[peerID]?.name ?? peerID)
        }
        self.log.warning("presence.session_conflict", [
            "parties": names.joined(separator: " + "),
            "ids": parties.joined(separator: ","),
        ])
        self.sessionConflictDetected(deviceNames: names)
        await self.onSessionConflict?(parties)
    }

    private func tickConnections(_ now: Date) async {
        for connection in self.connections.values {
            await connection.tick(now: now)
        }
        for connection in self.pendingInbound.values {
            await connection.tick(now: now)
        }
    }

    /// Starts every dial whose backoff window elapsed: one dial per peer in
    /// flight, and the smaller id dials unless the peer was dialed manually
    /// (tie-break, contract section 3).
    private func dialDuePeers(_ now: Date) async {
        let dueIDs = self.peers
            .filter { id, record in
                self.connections[id] == nil
                    && record.discovery != .gone
                    && !record.suppressReconnect
                    && record.endpoint != nil
                    && record.nextDialAt.map { now >= $0 } == true
                    && (record.isManual || Self.shouldDial(selfID: self.identity.id, peerID: id))
            }
            .map(\.key)
        for peerID in dueIDs {
            guard var record = self.peers[peerID], let endpoint = record.endpoint else { continue }
            record.nextDialAt = nil
            record.connection = .connecting
            self.peers[peerID] = record
            self.log.debug("presence.connect_attempt", [
                "peer": peerID,
                "addr": Self.describe(endpoint),
                "via": record.isManual ? "manual" : "tie-break",
            ])
            await self.dial(
                peerID: peerID,
                endpoint: endpoint,
                hostPort: record.hostPort,
                expectedPeerID: record.isManual ? nil : peerID
            )
        }
    }

    /// The tie-break rule (contract section 3): the lexicographically smaller
    /// device id dials, the other side waits.
    static func shouldDial(selfID: String, peerID: String) -> Bool {
        selfID < peerID
    }

    static func describe(_ endpoint: NWEndpoint) -> String {
        String(describing: endpoint)
    }
}

// MARK: - Discovery churn defenses

extension PresenceEngine {
    /// mDNS removal hints are debounced (`removalDebounce`), and a peer whose
    /// socket is CONNECTED with fresh pongs is never marked gone from a
    /// discovery hint alone (the measured NSD/Bonjour churn defense).
    func applyExpiredRemovals(_ now: Date) {
        let expired = self.peers
            .filter { _, record in
                guard let since = record.pendingRemovalSince else { return false }
                return now.timeIntervalSince(since) >= self.config.removalDebounce
            }
            .map(\.key)
        for peerID in expired {
            guard var record = self.peers[peerID] else { continue }
            record.pendingRemovalSince = nil
            self.peers[peerID] = record
            self.markGone(peerID: peerID, reason: "mDNS service removed")
        }
    }

    /// 60 s discovery-expiry backstop for peers with no socket (contract
    /// section 2). Connected peers are exempt (the MVP's defect 1), the
    /// announcement clock refreshes on every valid message, and expiry never
    /// sends goodbye.
    func expireStalePeers(_ now: Date) {
        let staleIDs = self.peers
            .filter { _, record in
                record.discovery == .discovered
                    && self.connections[record.id] == nil
                    && !record.isManual
                    && now.timeIntervalSince(record.lastAnnounce) > self.config.peerExpiry
            }
            .map(\.key)
        for peerID in staleIDs {
            self.markGone(peerID: peerID, reason: "no re-announcement for \(Int(self.config.peerExpiry))s")
        }
    }

    /// Marks a peer gone: stops dialing, suppresses reconnect until it
    /// reappears, closes any socket it still holds, and logs `peer_lost`.
    func markGone(peerID: String, reason: String) {
        guard var record = self.peers[peerID] else { return }
        guard record.discovery != .gone else { return }
        record.discovery = .gone
        record.nextDialAt = nil
        record.suppressReconnect = true
        record.pendingRemovalSince = nil
        self.peers[peerID] = record
        self.log.debug("presence.peer_lost", ["peer": peerID, "name": record.name, "reason": reason])
        // Session view: a gone stint stays visible as last-known, now .gone.
        self.sessionPeerGone(peerID: peerID)
        if let connection = self.connections[peerID] {
            Task { await connection.closeLocally(code: 1000, reason: reason, cause: .remote) }
        }
        self.publishSnapshot()
    }
}
