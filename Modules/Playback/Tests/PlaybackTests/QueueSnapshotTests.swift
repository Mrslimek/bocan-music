import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - QueueSnapshotTests
// Queue sharing (music-share protocol section 9): the queue-snapshot fan-out
// must deliver the queue contents + current index and re-emit on changes,
// while play/pause (no QueueChange) emits nothing.

@Suite("Queue snapshot fan-out")
struct QueueSnapshotTests {
    private func makeItem(trackID: Int64) -> QueueItem {
        QueueItem(
            trackID: trackID,
            bookmark: nil,
            fileURL: "/tmp/t\(trackID).flac",
            duration: 200,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100,
                bitDepth: 16,
                channelCount: 2,
                isInterleaved: false,
                codec: "flac"
            )
        )
    }

    @Test("snapshot stream seeds the current queue and re-emits on change")
    func seedsAndReEmits() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)
        // The queue-change consumer (which feeds the snapshot fan-out) attaches
        // during activation; mutating before it attaches loses events by design.
        await player.waitUntilActivated()
        let stream = await player.queueSnapshotUpdates()
        var iterator = stream.makeAsyncIterator()

        let seed = await iterator.next()
        #expect(seed?.items.isEmpty == true)
        #expect(seed?.currentIndex == nil)

        let items = [self.makeItem(trackID: 1), self.makeItem(trackID: 2)]
        await player.queue.replace(with: items, startAt: 1)
        let updated = await iterator.next()
        #expect(updated?.items.count == 2)
        #expect(updated?.currentIndex == 1)
    }

    @Test("pause emits no queue snapshot (no QueueChange)")
    func pauseDoesNotEmit() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)
        await player.waitUntilActivated()
        let stream = await player.queueSnapshotUpdates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // seed

        // Bounded negative check: a collecting consumer sees nothing within
        // a short window (never await next() — an absent emission would hang).
        let collector = Task {
            var received = 0
            for await _ in stream { received += 1 }
            return received
        }
        await player.pause()
        try? await Task.sleep(nanoseconds: 300_000_000)
        collector.cancel()
        let received = await collector.value
        #expect(received == 0)
    }
}
