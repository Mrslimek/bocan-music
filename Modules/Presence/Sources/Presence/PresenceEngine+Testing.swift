import Foundation

// MARK: - Test hooks (internal; visible to PresenceTests via @testable)

/// The engine's decision surface, without needing live sockets: tests drive
/// discovery events and state updates directly and read the resulting peer
/// records and own state.
extension PresenceEngine {
    /// Whether the bound listener ended up on the BSD fallback stack.
    func usingFallbackForTesting() async -> Bool {
        await self.listener?.effectiveStack == .bsdSocket
    }

    func currentPeersForTesting() -> [PeerSnapshot] {
        self.buildSnapshots()
    }

    func nextDialAtForTesting(peerID: String) -> Date? {
        self.peers[peerID]?.nextDialAt
    }

    func backoffIndexForTesting(peerID: String) -> Int? {
        self.peers[peerID]?.backoffIndex
    }

    func seenSeqForTesting(peerID: String) -> Int? {
        self.peers[peerID]?.lastSeenSeq
    }

    func ownStateForTesting() -> PresencePlaybackState {
        self.ownState
    }

    func seedPeerForTesting(peerID: String, name: String) {
        var record = PeerRecord(id: peerID, name: name, endpoint: nil, lastAnnounce: Date())
        record.discovery = .discovered
        self.peers[peerID] = record
    }

    func receiveStateForTesting(peerID: String, state: PresencePlaybackState) async {
        await self.applyReceivedState(peerID: peerID, state: state)
    }

    func applyExpiredRemovalsForTesting(now: Date) {
        self.applyExpiredRemovals(now)
    }

    func expireStalePeersForTesting(now: Date) {
        self.expireStalePeers(now)
    }

    func applyOwnStateForTesting(_ state: PresencePlaybackState) async {
        await self.applyOwnState(state)
    }

    /// Feeds an inbound command through the receiver path (gate, executor,
    /// logging) without needing a live socket.
    func applyInboundCommandForTesting(_ command: PresenceCommand, owner: String) async {
        await self.applyInboundCommand(command, owner: owner)
    }

    /// Test seam for the accept path without NWListener (which cannot bind in
    /// restricted environments): adopts an already-open transport as an
    /// inbound callee socket, exactly as `acceptInbound` would.
    func adoptInboundTransportForTesting(_ transport: WSTransport) async {
        await self.registerConnection(
            role: .callee,
            socket: transport,
            expectedPeerID: nil,
            ownerKey: "pending:\(UUID())",
            pending: true
        )
    }

    /// Test seam for the dial path without NWConnection: opens an outbound
    /// caller connection over an injected transport with manual semantics.
    func openOutboundForTesting(ownerKey: String, transport: WSTransport) async {
        await self.registerConnection(
            role: .caller,
            socket: transport,
            expectedPeerID: nil,
            ownerKey: ownerKey,
            pending: false
        )
    }
}
