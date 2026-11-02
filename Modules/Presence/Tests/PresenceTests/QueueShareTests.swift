import AudioEngine
import Foundation
import Observability
import Playback
import Synchronization
import Testing
@testable import Presence

// MARK: - Queue sharing sender (contract section 9)

@Suite
struct QueueShareSenderTests {
    private static func hash(_ seed: UInt8) -> String {
        String(repeating: String(format: "%02x", seed), count: 32)
    }

    private func snapshot(trackIDs: [Int64], currentIndex: Int?) -> QueueSnapshot {
        QueueSnapshot(
            items: trackIDs.map { Self.makeItem(trackID: $0) },
            currentIndex: currentIndex
        )
    }

    private static func makeItem(trackID: Int64) -> QueueItem {
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

    private func makeQueueEngine(
        selfID: String,
        store: LogStore,
        hashes: @escaping @Sendable (Int64) async -> String? = { Self.hash(UInt8(clamping: $0)) }
    ) -> PresenceEngine {
        let config = PresenceConfig(
            pingInterval: 0.2,
            pongTimeout: 0.8,
            handshakeTimeout: 0.8,
            dialTimeout: 0.8,
            peerExpiry: 2.0,
            removalDebounce: 0.3,
            healthyPongAge: 1.0,
            tickInterval: 0.1,
            usesDiscovery: false,
            bindsListener: false,
            queueDebounce: 0.05
        )
        return Harness.makeEngine(
            selfID: selfID,
            name: "BocanQ",
            config: config,
            trackHashProvider: hashes,
            store: store
        )
    }

    @Test
    func queueMessageMapsItemsThroughTheHashProvider() async {
        let engine = makeQueueEngine(selfID: "qqq", store: LogStore(capacity: 100))
        let message = await engine.queueMessage(from: snapshot(trackIDs: [10, 11, 12], currentIndex: 1))
        #expect(message.hashes == [Self.hash(10), Self.hash(11), Self.hash(12)])
        #expect(message.current == 1)
    }

    @Test
    func unresolvableEntriesAreDroppedAndCurrentFollows() async {
        let engine = makeQueueEngine(
            selfID: "qqq",
            store: LogStore(capacity: 100)
        ) { $0 == 11 ? nil : Self.hash(UInt8(clamping: $0)) }
        let message = await engine.queueMessage(from: snapshot(trackIDs: [10, 11, 12], currentIndex: 2))
        #expect(message.hashes == [Self.hash(10), Self.hash(12)])
        #expect(message.current == 1)
    }

    @Test
    func windowCapRespectedForLargeQueues() async {
        let engine = makeQueueEngine(selfID: "qqq", store: LogStore(capacity: 100))
        let ids = (1...250).map { Int64($0) }
        let message = await engine.queueMessage(from: snapshot(trackIDs: ids, currentIndex: 240))
        #expect(message.hashes?.count == 200)
        // The 200-entry window is clamped to the tail; 240 sits at offset 190.
        #expect(message.current == 190)
    }

    @Test
    func emptyQueueSendsEmptyHashes() async {
        let engine = makeQueueEngine(selfID: "qqq", store: LogStore(capacity: 100))
        let message = await engine.queueMessage(from: snapshot(trackIDs: [], currentIndex: nil))
        #expect(message.hashes?.isEmpty == true)
        #expect(message.current == nil)
    }
}

@Suite(.serialized)
struct QueueShareLoopbackTests {
    private static func loopbackConfig() -> PresenceConfig {
        PresenceConfig(
            pingInterval: 0.3,
            pongTimeout: 2.0,
            handshakeTimeout: 3.0,
            dialTimeout: 3.0,
            peerExpiry: 60,
            removalDebounce: 0.5,
            healthyPongAge: 3.0,
            tickInterval: 0.05,
            usesDiscovery: false,
            bindsListener: false,
            queueDebounce: 0.05
        )
    }

    private static func hash(_ seed: UInt8) -> String {
        String(repeating: String(format: "%02x", seed), count: 32)
    }

    @Test
    func queueLoopbackReceiverGetsSendersHashes() async throws {
        let storeA = LogStore(capacity: 2000)
        let storeB = LogStore(capacity: 2000)
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            config: Self.loopbackConfig(),
            trackHashProvider: { Self.hash(UInt8(clamping: $0)) },
            store: storeA
        )
        let engineB = Harness.makeEngine(selfID: "loop-zzz", name: "BocanB", config: Self.loopbackConfig(), store: storeB)
        // A fabricated queue: three tracks, second one current.
        await engineA.setQueueSnapshotForTesting {
            QueueSnapshot(
                items: [1, 2, 3].map { Self.makeItem(trackID: Int64($0)) },
                currentIndex: 1
            )
        }

        try await engineA.start()
        try await engineB.start()
        let (sideA, sideB) = PairedTransport.pair()
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)

        let connected = await waitUntil(within: 8) { [engineB] in
            await (engineB.currentPeersForTesting()).contains {
                $0.id == "loop-aaa" && $0.connection == .connected
            }
        }
        #expect(connected)

        let bGotQueue = await waitUntil(within: 4) { [storeB] in
            storeB.snapshot().contains { $0.message.contains("queue_recv") }
        }
        #expect(bGotQueue)
        let recv = storeB.snapshot().first { $0.message.contains("queue_recv") }
        #expect(recv?.message.contains("entries=3") == true)
        #expect(recv?.message.contains("current=1") == true)

        await engineA.stop()
        await engineB.stop()
    }

    @Test
    func trackAdvanceResendsWithUpdatedCurrent() async throws {
        let storeB = LogStore(capacity: 2000)
        let engineA = Harness.makeEngine(
            selfID: "loop-aaa",
            name: "BocanA",
            config: Self.loopbackConfig(),
            trackHashProvider: { Self.hash(UInt8(clamping: $0)) },
            store: LogStore(capacity: 500)
        )
        let engineB = Harness.makeEngine(selfID: "loop-zzz", name: "BocanB", config: Self.loopbackConfig(), store: storeB)
        await engineA.setQueueSnapshotForTesting {
            QueueSnapshot(
                items: [1, 2, 3].map { Self.makeItem(trackID: Int64($0)) },
                currentIndex: 0
            )
        }

        try await engineA.start()
        try await engineB.start()
        let (sideA, sideB) = PairedTransport.pair()
        await engineA.openOutboundForTesting(ownerKey: "manual:loop", transport: sideA)
        await engineB.adoptInboundTransportForTesting(sideB)

        let first = await waitUntil(within: 8) { [storeB] in
            storeB.snapshot().contains { $0.message.contains("queue_recv") }
        }
        #expect(first)

        // Track advance: the current index moves; the debounced re-send lands.
        await engineA.setQueueSnapshotForTesting {
            QueueSnapshot(
                items: [1, 2, 3].map { Self.makeItem(trackID: Int64($0)) },
                currentIndex: 1
            )
        }
        await engineA.handleQueueSnapshotForTesting(QueueSnapshot(
            items: [1, 2, 3].map { Self.makeItem(trackID: Int64($0)) },
            currentIndex: 1
        ))
        let advanced = await waitUntil(within: 8) { [storeB] in
            storeB.snapshot().filter { $0.message.contains("queue_recv") }.count == 2
        }
        #expect(advanced)
        let second = storeB.snapshot().filter { $0.message.contains("queue_recv") }[1]
        #expect(second.message.contains("current=1") == true)

        await engineA.stop()
        await engineB.stop()
    }

    @Test
    func unchangedContentDoesNotResend() async throws {
        let engine = Harness.makeEngine(
            selfID: "qqq",
            name: "BocanQ",
            config: Self.loopbackConfig(),
            trackHashProvider: { Self.hash(UInt8(clamping: $0)) },
            store: LogStore(capacity: 500)
        )
        try await engine.start()
        let snap = QueueSnapshot(items: [1, 2].map { Self.makeItem(trackID: Int64($0)) }, currentIndex: 0)

        await engine.handleQueueSnapshotForTesting(snap)
        let sentOnce = await waitUntil(within: 4) { [engine] in
            await engine.lastQueueFingerprintForTesting() != nil
        }
        #expect(sentOnce)

        // Identical content again: suppressed, no second fingerprint change.
        await engine.handleQueueSnapshotForTesting(snap)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let sent = await engine.lastQueueFingerprintForTesting()
        #expect(sent?.current == 0)
        #expect(sent?.hashes.count == 2)

        await engine.stop()
    }

    private static func makeItem(trackID: Int64) -> QueueItem {
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
}
