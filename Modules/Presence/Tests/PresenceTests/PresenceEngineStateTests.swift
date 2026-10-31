import AudioEngine
import Foundation
import Observability
import Playback
import Testing
@testable import Presence

// MARK: - Seq / conflict logic, own-state policy, expiry

struct PresenceEngineStateTests {
    @Test
    func newestArrivalDisplayedAndConflictLogged() async {
        let store = LogStore(capacity: 500)
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle", store: store)
        await engine.seedPeerForTesting(peerID: "zzz", name: "Remote")

        await engine.receiveStateForTesting(
            peerID: "zzz",
            state: PresencePlaybackState(track: "Song A", status: .playing, positionSec: 10, seq: 5)
        )
        await engine.receiveStateForTesting(
            peerID: "zzz",
            state: PresencePlaybackState(track: "Song B", status: .playing, positionSec: 20, seq: 6)
        )
        #expect(await engine.seenSeqForTesting(peerID: "zzz") == 6)
        let snapshot = await engine.currentPeersForTesting()
        let newest = snapshot.first { $0.id == "zzz" }?.playback?.track
        #expect(newest == "Song B")

        // A non-advancing seq still displays (newest arrival wins) but is
        // logged as a conflict.
        await engine.receiveStateForTesting(
            peerID: "zzz",
            state: PresencePlaybackState(track: "Song C", status: .paused, positionSec: 1, seq: 2)
        )
        #expect(await engine.seenSeqForTesting(peerID: "zzz") == 2)
        let snapshotAfterConflict = await engine.currentPeersForTesting()
        let afterConflict = snapshotAfterConflict.first { $0.id == "zzz" }?.playback?.track
        #expect(afterConflict == "Song C")

        let conflicts = store.snapshot().filter { $0.message.contains("state_conflict") }
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.message.contains("seq=2") == true)
        #expect(conflicts.first?.message.contains("lastSeq=6") == true)
    }

    @Test
    func equalSeqLogsConflict() async {
        let store = LogStore(capacity: 500)
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle", store: store)
        await engine.seedPeerForTesting(peerID: "zzz", name: "Remote")
        await engine.receiveStateForTesting(
            peerID: "zzz",
            state: PresencePlaybackState(track: "A", status: .playing, positionSec: 1, seq: 3)
        )
        await engine.receiveStateForTesting(
            peerID: "zzz",
            state: PresencePlaybackState(track: "B", status: .playing, positionSec: 2, seq: 3)
        )
        let conflicts = store.snapshot().filter { $0.message.contains("state_conflict") }
        #expect(conflicts.count == 1)
    }

    @Test
    func firstOwnStateBroadcastsSeq1AndDiscreteChangesBump() async {
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle")

        await engine.applyOwnStateForTesting(
            PresencePlaybackState(track: "Song", status: .playing, positionSec: 1, seq: 0)
        )
        #expect(await engine.ownStateForTesting().seq == 1)

        // Position-only drift inside the refresh window: seq holds.
        await engine.applyOwnStateForTesting(
            PresencePlaybackState(track: "Song", status: .playing, positionSec: 2, seq: 0)
        )
        #expect(await engine.ownStateForTesting().seq == 1)
        #expect(await engine.ownStateForTesting().positionSec == 2)

        // A track change always broadcasts and bumps.
        await engine.applyOwnStateForTesting(
            PresencePlaybackState(track: "Next", status: .playing, positionSec: 3, seq: 0)
        )
        #expect(await engine.ownStateForTesting().seq == 2)
        #expect(await engine.ownStateForTesting().track == "Next")

        // A status change always broadcasts and bumps.
        await engine.applyOwnStateForTesting(
            PresencePlaybackState(track: "Next", status: .paused, positionSec: 3, seq: 0)
        )
        #expect(await engine.ownStateForTesting().seq == 3)
    }

    @Test
    func playbackTapMapping() {
        let item = QueueItem(
            trackID: 1,
            bookmark: nil,
            fileURL: "file:///x",
            duration: 100,
            sourceFormat: AudioSourceFormat(sampleRate: 44100, bitDepth: 16, channelCount: 2, isInterleaved: false, codec: "flac"),
            title: "Title",
            artistName: "Artist"
        )
        let playing = PlaybackTap.mapped(state: .playing, item: item, position: 42.5, trackHash: nil)
        #expect(playing.status == .playing)
        #expect(playing.track == "Title")
        #expect(playing.artist == "Artist")
        #expect(playing.positionSec == 42.5)

        let paused = PlaybackTap.mapped(state: .paused, item: item, position: 10, trackHash: nil)
        #expect(paused.status == .paused)

        // Everything else (idle, loading, ended, stopped, failed) is stopped.
        let stopped = PlaybackTap.mapped(state: .ended, item: nil, position: 0, trackHash: nil)
        #expect(stopped.status == .stopped)
        #expect(stopped.track.isEmpty)
    }

    @Test
    func socketlessPeerExpiresAfterTheDiscoveryWindow() async {
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle")
        await engine.seedPeerForTesting(peerID: "zzz", name: "Remote")
        await engine.expireStalePeersForTesting(now: Date().addingTimeInterval(120))
        let snapshot = await engine.currentPeersForTesting()
        let discovery = snapshot.first { $0.id == "zzz" }?.discovery
        #expect(discovery == .gone)
    }

    @Test
    func removalDebounceHoldsUntilWindowElapses() async {
        let engine = Harness.makeEngine(selfID: "mmm", name: "Middle")
        await engine.seedPeerForTesting(peerID: "zzz", name: "Remote")

        // A removal hint inside the debounce window does not mark gone.
        await engine.handleRemovalHint(peerID: "zzz")
        let now = Date()
        await engine.applyExpiredRemovalsForTesting(now: now.addingTimeInterval(0.1))
        var snapshot = await engine.currentPeersForTesting()
        let discovery = snapshot.first { $0.id == "zzz" }?.discovery
        #expect(discovery == .discovered)

        // Past the window, the debounced removal applies.
        await engine.applyExpiredRemovalsForTesting(now: now.addingTimeInterval(10))
        snapshot = await engine.currentPeersForTesting()
        let afterWindow = snapshot.first { $0.id == "zzz" }?.discovery
        #expect(afterWindow == .gone)
    }
}
