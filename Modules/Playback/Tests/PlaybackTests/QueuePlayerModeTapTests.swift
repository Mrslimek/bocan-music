import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - QueuePlayerModeTapTests
// Playback-mode extension (music-share protocol 2026-11-02): the playback tap
// must report the current queue modes and re-emit when setRepeat/setShuffle
// change them.

@Suite("QueuePlayer mode tap")
struct QueuePlayerModeTapTests {
    private func makePlayer() async throws -> (QueuePlayer, AsyncStream<PlaybackTapSnapshot>.Iterator) {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)
        let stream = await player.playbackTapUpdates()
        return (player, stream.makeAsyncIterator())
    }

    @Test("initial snapshot carries the current modes")
    func initialSnapshotModes() async throws {
        let pair = try await self.makePlayer()
        let player = pair.0
        var iterator = pair.1
        await player.setRepeat(.one)
        await player.setShuffle(true)
        _ = await iterator.next() // the seed taken at subscription time
        let repeatSnap = await iterator.next() // setRepeat emission
        #expect(repeatSnap?.repeat == .one)
        let snapshot = await iterator.next() // setShuffle emission
        #expect(snapshot?.shuffle == true)
    }

    @Test("setRepeat re-emits with the new mode", arguments: [
        RepeatMode.off, RepeatMode.all, RepeatMode.one,
    ])
    func setRepeatEmits(mode: RepeatMode) async throws {
        let pair = try await self.makePlayer()
        let player = pair.0
        var iterator = pair.1
        _ = await iterator.next()
        await player.setRepeat(mode)
        let snapshot = await iterator.next()
        #expect(snapshot?.repeat == mode)
        #expect(await player.queue.repeatMode == mode)
    }

    @Test("setShuffle re-emits with the new flag")
    func setShuffleEmits() async throws {
        let pair = try await self.makePlayer()
        let player = pair.0
        var iterator = pair.1
        _ = await iterator.next()
        await player.setShuffle(true)
        let on = await iterator.next()
        #expect(on?.shuffle == true)
        await player.setShuffle(false)
        let off = await iterator.next()
        #expect(off?.shuffle == false)
    }
}
