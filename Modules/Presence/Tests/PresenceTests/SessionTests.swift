import Foundation
import Observability
import Synchronization
import Testing

@testable import Presence

// MARK: - Shared session (contract section 8)

@Suite
struct SessionCodecTests {
    @Test
    func stateRoundTripWithSessionFields() throws {
        let state = PresencePlaybackState(
            track: "Hallelujah",
            status: .playing,
            positionSec: 42.5,
            seq: 7,
            trackHash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2",
            playbackId: "0b9e6c1e-0a2b-4c3d-8e4f-a1b2c3d4e5f6"
        )
        let text = try WireCodec.encode(.stateUpdate(state), from: "aaa", nowMs: 1)
        guard case let .message(.stateUpdate(decoded), _) = WireCodec.decode(text) else {
            Issue.record("expected state_update")
            return
        }
        #expect(decoded == state)
        #expect(text.contains("\"trackHash\":\"a1b2"))
        #expect(text.contains("\"playbackId\":\"0b9e6c1e"))
    }

    @Test
    func stateWithoutSessionFieldsStaysAbsentOnTheWire() throws {
        let state = PresencePlaybackState(track: "Song", status: .paused, positionSec: 1, seq: 2)
        let text = try WireCodec.encode(.stateUpdate(state), from: "aaa", nowMs: 1)
        guard case let .message(.stateUpdate(decoded), _) = WireCodec.decode(text) else {
            Issue.record("expected state_update")
            return
        }
        #expect(decoded.trackHash == nil)
        #expect(decoded.playbackId == nil)
        #expect(!text.contains("trackHash"))
        #expect(!text.contains("playbackId"))
    }
}

/// Takeover and conflict over the in-memory paired-transport harness.
@Suite
struct SessionEngineTests {
    /// One `onPeerBecameActive` firing, captured for assertions.
    private struct ActivationEvent: Equatable {
        let peerID: String
        let trackHash: String?
        let positionSec: Double
        let playbackId: String
    }
    private static func capableState(
        _ status: PresenceStatus,
        position: Double,
        seq: Int,
        hash: String = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2",
        playbackId: String? = nil
    ) -> PresencePlaybackState {
        PresencePlaybackState(
            track: "Hallelujah",
            status: status,
            positionSec: position,
            seq: seq,
            trackHash: hash,
            playbackId: playbackId
        )
    }

    @Test
    func peerBecameActiveFiresOnFreshStintWithPositionAndPlaybackId() async {
        let storeA = LogStore(capacity: 1000)
        let fired = Mutex<ActivationEvent?>(nil)
        let onActive: @Sendable (String, String, String?, Double, String) async -> Void = { peerID, _, trackHash, position, playbackId in
            let event = ActivationEvent(
                peerID: peerID,
                trackHash: trackHash,
                positionSec: position,
                playbackId: playbackId
            )
            fired.withLock { $0 = event }
        }
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            onPeerBecameActive: onActive,
            store: storeA
        )
        await engineA.seedPeerForTesting(peerID: "loop-zzz", name: "BocanB")

        // B was paused without session fields, then reports a fresh playing
        // stint: the takeover signal.
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: PresencePlaybackState(track: "Hallelujah", status: .paused, positionSec: 40, seq: 1)
        )
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: Self.capableState(.playing, position: 42.5, seq: 2, playbackId: "stint-b")
        )

        let event = fired.withLock { $0 }
        #expect(event?.peerID == "loop-zzz")
        #expect(event?.trackHash == "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2")
        #expect(event?.positionSec == 42.5)
        #expect(event?.playbackId == "stint-b")
        let logged = storeA.snapshot().filter { $0.message.contains("session.peer_active") }
        #expect(logged.count == 1)
        #expect(logged.first?.message.contains("name=BocanB") == true)
    }

    @Test
    func pauseResumeOfTheSameStintDoesNotFire() async {
        let fired = Mutex<Bool>(false)
        let onActive: @Sendable (String, String, String?, Double, String) async -> Void = { _, _, _, _, _ in
            fired.withLock { $0 = true }
        }
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            onPeerBecameActive: onActive
        )
        await engineA.seedPeerForTesting(peerID: "loop-zzz", name: "BocanB")

        // The first playing report is itself a fresh stint: consume it.
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: Self.capableState(.playing, position: 10, seq: 1, playbackId: "stint-b")
        )
        #expect(fired.withLock { $0 } == true)
        fired.withLock { $0 = false }

        // Pause, then resume the SAME stint: no second firing.
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: Self.capableState(.paused, position: 12, seq: 2, playbackId: "stint-b")
        )
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: Self.capableState(.playing, position: 12, seq: 3, playbackId: "stint-b")
        )
        #expect(fired.withLock { $0 } == false)
    }

    @Test
    func peerWithoutTrackHashIsNotSessionCapable() async {
        let fired = Mutex<Bool>(false)
        let onActive: @Sendable (String, String, String?, Double, String) async -> Void = { _, _, _, _, _ in
            fired.withLock { $0 = true }
        }
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            onPeerBecameActive: onActive
        )
        await engineA.seedPeerForTesting(peerID: "loop-zzz", name: "BocanB")

        // Playing with a playbackId but no trackHash: absent trackHash means
        // the peer does not participate in the session extension.
        await engineA.receiveStateForTesting(
            peerID: "loop-zzz",
            state: PresencePlaybackState(
                track: "Song",
                status: .playing,
                positionSec: 1,
                seq: 1,
                playbackId: "stint-b"
            )
        )
        #expect(fired.withLock { $0 } == false)
    }

    /// The full takeover cycle over the wire: A playing, B takes over with a
    /// fresh stint at A's position, and A's engine both fires the callback
    /// and shows B's fresh playbackId in its snapshot.
    @Test
    func takeoverCycleOverLoopback() async throws {
        let fired = Mutex<ActivationEvent?>(nil)
        let onActive: @Sendable (String, String, String?, Double, String) async -> Void = { peerID, _, _, position, playbackId in
            let event = ActivationEvent(
                peerID: peerID,
                trackHash: nil,
                positionSec: position,
                playbackId: playbackId
            )
            fired.withLock { $0 = event }
        }
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            onPeerBecameActive: onActive
        )
        let engineB = Harness.makeEngine(selfID: "loop-zzz", name: "BocanB")

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

        // A plays Hallelujah at 42.5 (a session-capable state).
        await engineA.applyOwnStateForTesting(Self.capableState(.playing, position: 42.5, seq: 0))
        let aPlaying = await waitUntil(within: 4) { [engineB] in
            await (engineB.currentPeersForTesting()).first { $0.id == "loop-aaa" }?.playback?.status == .playing
        }
        #expect(aPlaying)

        // B takes over: starts the same track at A's position with its own
        // (engine-assigned) stint id. The beginPlaybackStint call is what the
        // handoff UI does before starting local playback.
        await engineB.beginPlaybackStint()
        await engineB.applyOwnStateForTesting(Self.capableState(.playing, position: 42.5, seq: 0))

        let eventShown = await waitUntil(within: 4) { () -> Bool in
            fired.withLock { $0 != nil }
        }
        #expect(eventShown)
        let event = fired.withLock { $0 }
        #expect(event?.peerID == "loop-zzz")
        #expect(event?.positionSec == 42.5)

        // B reports a fresh playbackId at A's position in A's snapshot.
        let bPlayback = await engineA.currentPeersForTesting().first { $0.id == "loop-zzz" }?.playback
        #expect(bPlayback?.playbackId != nil)
        #expect(bPlayback?.positionSec == 42.5)
        #expect(bPlayback?.trackHash == "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2")

        await engineA.stop()
        await engineB.stop()
    }

    /// Two playing devices past the handoff grace: session_conflict fires on
    /// both engines, names both device ids, and neither engine auto-resolves
    /// (both stay playing).
    @Test
    func conflictFiresPastGraceOnBothSides() async throws {
        let pair = await Self.makeConflictingPair()
        let engineA = pair.engineA
        let engineB = pair.engineB
        let storeA = pair.storeA

        let aFired = await waitUntil(within: 4) { () -> Bool in
            pair.firedA.parties != nil
        }
        #expect(aFired)
        let bFired = await waitUntil(within: 4) { () -> Bool in
            pair.firedB.parties != nil
        }
        #expect(bFired)

        let aParties = pair.firedA.parties ?? []
        #expect(aParties.contains("loop-aaa") && aParties.contains("loop-zzz"))
        let logged = storeA.snapshot().filter { $0.message.contains("session_conflict") }
        #expect(logged.count == 1)
        #expect(logged.first?.message.contains("BocanA + BocanB") == true)

        // Never auto-resolved: both still playing after the event.
        let aStillPlaying = await engineA.ownStateForTesting().status == .playing
        let bStillPlaying = await engineB.ownStateForTesting().status == .playing
        #expect(aStillPlaying && bStillPlaying)

        await engineA.stop()
        await engineB.stop()
    }

    /// One conflict observer (a copyable box around the fired parties).
    final class ConflictBox: @unchecked Sendable {
        var parties: [String]?
    }

    /// A connected pair with BOTH engines playing session-capable tracks past
    /// the grace.
    /// A connected pair with both engines playing.
    private struct ConflictingPair {
        let engineA: PresenceEngine
        let engineB: PresenceEngine
        let storeA: LogStore
        let storeB: LogStore
        let firedA: ConflictBox
        let firedB: ConflictBox
    }

    private static func makeConflictingPair() async -> ConflictingPair {
        let conflictConfig = PresenceConfig(
            pingInterval: 5,
            pongTimeout: 10,
            handshakeTimeout: 5,
            dialTimeout: 5,
            tickInterval: 0.05,
            usesDiscovery: false,
            bindsListener: false,
            sessionConflictGrace: 0.3
        )
        let storeA = LogStore(capacity: 1000)
        let storeB = LogStore(capacity: 1000)
        let firedA = ConflictBox()
        let firedB = ConflictBox()
        let onConflictA: @Sendable ([String]) async -> Void = { parties in
            firedA.parties = parties
        }
        let onConflictB: @Sendable ([String]) async -> Void = { parties in
            firedB.parties = parties
        }
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            config: conflictConfig,
            onSessionConflict: onConflictA,
            store: storeA
        )
        let engineB = Harness.makeEngine(
            selfID: "loop-zzz",
            name: "BocanB",
            config: conflictConfig,
            onSessionConflict: onConflictB,
            store: storeB
        )
        try? await engineA.start()
        try? await engineB.start()
        let pair = ConflictingPair(
            engineA: engineA,
            engineB: engineB,
            storeA: storeA,
            storeB: storeB,
            firedA: firedA,
            firedB: firedB
        )
        await Self.connectAndPlay(pair)
        return pair
    }

    private static func connectAndPlay(_ pair: ConflictingPair) async {
        let engineA = pair.engineA
        let engineB = pair.engineB
        let (sideA, sideB) = PairedTransport.pair()
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)
        let connected = await waitUntil(within: 8) { [engineA] in
            await (engineA.currentPeersForTesting()).contains {
                $0.id == "loop-zzz" && $0.connection == .connected
            }
        }
        guard connected else {
            Issue.record("pair did not connect")
            return
        }
        await engineA.applyOwnStateForTesting(Self.capableState(.playing, position: 40, seq: 0))
        await engineB.applyOwnStateForTesting(Self.capableState(.playing, position: 42.5, seq: 0))
    }

    /// An overlap that ends inside the handoff grace must not produce a
    /// false session_conflict.
    @Test
    func overlapWithinGraceDoesNotFire() async throws {
        let conflictConfig = PresenceConfig(
            pingInterval: 5,
            pongTimeout: 10,
            handshakeTimeout: 5,
            dialTimeout: 5,
            tickInterval: 0.05,
            usesDiscovery: false,
            bindsListener: false,
            sessionConflictGrace: 2.0
        )
        let storeA = LogStore(capacity: 1000)
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            config: conflictConfig,
            store: storeA
        )
        let engineB = Harness.makeEngine(selfID: "loop-zzz", name: "BocanB", config: conflictConfig)

        try await engineA.start()
        try await engineB.start()
        let (sideA, sideB) = PairedTransport.pair()
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)
        let connected = await waitUntil(within: 8) { [engineA] in
            await (engineA.currentPeersForTesting()).contains {
                $0.id == "loop-zzz" && $0.connection == .connected
            }
        }
        #expect(connected)

        // A legal handoff: both playing briefly, then A pauses.
        await engineA.applyOwnStateForTesting(Self.capableState(.playing, position: 40, seq: 0))
        await engineB.applyOwnStateForTesting(Self.capableState(.playing, position: 42.5, seq: 0))
        try await Task.sleep(nanoseconds: 700_000_000)
        await engineA.applyOwnStateForTesting(Self.capableState(.paused, position: 42.5, seq: 1))
        try await Task.sleep(nanoseconds: 700_000_000)

        let conflicts = storeA.snapshot().filter { $0.message.contains("session_conflict") }
        #expect(conflicts.isEmpty)

        await engineA.stop()
        await engineB.stop()
    }
}
