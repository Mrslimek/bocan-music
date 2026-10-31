import Foundation
import Observability
import Synchronization
import Testing

@testable import Presence

// MARK: - Remote playback control (contract section 6, command)

@Suite
struct CommandCodecTests {
    @Test
    func commandRoundTripWithPosition() throws {
        let text = try WireCodec.encode(.command(PresenceCommand(action: "seek", positionSec: 42.5)), from: "aaa", nowMs: 1)
        guard case let .message(.command(command), _) = WireCodec.decode(text) else {
            Issue.record("expected command")
            return
        }
        #expect(command.action == "seek")
        #expect(command.positionSec == 42.5)
    }

    @Test
    func commandRoundTripWithoutPosition() throws {
        let text = try WireCodec.encode(.command(PresenceCommand(action: "pause")), from: "aaa", nowMs: 1)
        guard case let .message(.command(command), _) = WireCodec.decode(text) else {
            Issue.record("expected command")
            return
        }
        #expect(command.action == "pause")
        #expect(command.positionSec == nil)
        #expect(!text.contains("positionSec"))
    }

    @Test
    func commandWithoutActionIsMalformed() {
        let json = "{\"v\":1,\"type\":\"command\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1,\"positionSec\":3}"
        guard case let .malformed(reason, type) = WireCodec.decode(json) else {
            Issue.record("expected malformed")
            return
        }
        #expect(type == "command")
        #expect(reason.contains("action"))
    }

    @Test
    func unknownActionsDecodeForTheReceiverRules() {
        // Unknown action strings must survive decoding so the receiver logs
        // command_ignored reason=unsupported instead of treating the frame as
        // malformed (contract section 6).
        let json = "{\"v\":1,\"type\":\"command\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1,\"action\":\"eject\"}"
        guard case let .message(.command(command), _) = WireCodec.decode(json) else {
            Issue.record("expected command")
            return
        }
        #expect(command.action == "eject")
        #expect(PresenceCommandAction(rawValue: command.action) == nil)
    }
}

@Suite
struct CommandReceiverTests {
    private func ignoredEntries(_ store: LogStore) -> [LogEntry] {
        store.snapshot().filter { $0.message.contains("command_ignored") }
    }

    @Test
    func appliedCommandInvokesExecutorAndLogsCommandRecv() async {
        let store = LogStore(capacity: 500)
        let executor = Mutex<(PresenceCommandAction, Double?)?>(nil)
        let engine = Harness.makeEngine(
            selfID: "mmm",
            name: "Middle",
            executor: { action, position in
                executor.withLock { $0 = (action, position) }
                return true
            },
            store: store
        )
        await engine.seedPeerForTesting(peerID: "zzz", name: "Pixel 8")

        await engine.applyInboundCommandForTesting(
            PresenceCommand(action: "pause", positionSec: nil),
            owner: "zzz"
        )
        let applied = executor.withLock { $0 }
        #expect(applied?.0 == .pause)
        #expect(applied?.1 == nil)

        let received = store.snapshot().filter { $0.message.contains("command_recv") }
        #expect(received.count == 1)
        #expect(received.first?.message.contains("action=pause") == true)
        #expect(received.first?.message.contains("name=Pixel 8") == true)
        #expect(ignoredEntries(store).isEmpty)
    }

    @Test
    func unknownActionIsIgnoredUnsupportedAndNeverReachesExecutor() async {
        let store = LogStore(capacity: 500)
        let calls = Mutex<Int>(0)
        let engine = Harness.makeEngine(
            selfID: "mmm",
            name: "Middle",
            executor: { _, _ in
                calls.withLock { $0 += 1 }
                return true
            },
            store: store
        )
        await engine.seedPeerForTesting(peerID: "zzz", name: "Pixel 8")

        await engine.applyInboundCommandForTesting(
            PresenceCommand(action: "eject", positionSec: nil),
            owner: "zzz"
        )
        #expect(calls.withLock { $0 } == 0)
        let ignored = ignoredEntries(store)
        #expect(ignored.count == 1)
        #expect(ignored.first?.message.contains("action=eject") == true)
        #expect(ignored.first?.message.contains("reason=unsupported") == true)
    }

    @Test
    func disabledGateIgnoresInboundCommands() async {
        let store = LogStore(capacity: 500)
        let calls = Mutex<Int>(0)
        let engine = Harness.makeEngine(
            selfID: "mmm",
            name: "Middle",
            controlEnabled: { false },
            executor: { _, _ in
                calls.withLock { $0 += 1 }
                return true
            },
            store: store
        )
        await engine.seedPeerForTesting(peerID: "zzz", name: "Pixel 8")

        await engine.applyInboundCommandForTesting(
            PresenceCommand(action: "play", positionSec: nil),
            owner: "zzz"
        )
        #expect(calls.withLock { $0 } == 0)
        let ignored = ignoredEntries(store)
        #expect(ignored.count == 1)
        #expect(ignored.first?.message.contains("reason=disabled") == true)
        #expect(ignored.first?.message.contains("action=play") == true)
    }

    @Test
    func seekWithoutPositionIsMalformed() async {
        let store = LogStore(capacity: 500)
        let calls = Mutex<Int>(0)
        let engine = Harness.makeEngine(
            selfID: "mmm",
            name: "Middle",
            executor: { _, _ in
                calls.withLock { $0 += 1 }
                return true
            },
            store: store
        )
        await engine.seedPeerForTesting(peerID: "zzz", name: "Pixel 8")

        await engine.applyInboundCommandForTesting(
            PresenceCommand(action: "seek", positionSec: nil),
            owner: "zzz"
        )
        #expect(calls.withLock { $0 } == 0)
        let malformed = store.snapshot().filter { $0.message.contains("message_malformed") }
        #expect(malformed.count == 1)
        #expect(malformed.first?.message.contains("positionSec") == true)
    }

    @Test
    func executorRefusalLogsUnsupported() async {
        let store = LogStore(capacity: 500)
        let engine = Harness.makeEngine(
            selfID: "mmm",
            name: "Middle",
            executor: { _, _ in false },
            store: store
        )
        await engine.seedPeerForTesting(peerID: "zzz", name: "Pixel 8")

        await engine.applyInboundCommandForTesting(
            PresenceCommand(action: "toggle", positionSec: nil),
            owner: "zzz"
        )
        let ignored = ignoredEntries(store)
        #expect(ignored.count == 1)
        #expect(ignored.first?.message.contains("reason=unsupported") == true)
        #expect(ignored.first?.message.contains("action=toggle") == true)
    }
}
