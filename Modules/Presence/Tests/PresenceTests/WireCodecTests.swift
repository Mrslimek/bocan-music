import Foundation
import Testing
@testable import Presence

// MARK: - Wire codec

struct WireCodecTests {
    @Test
    func helloRoundTrip() throws {
        let info = PresenceHelloInfo(name: "Mac mini", platform: "macos", appVersion: "1.0")
        let text = try WireCodec.encode(.hello(info), from: "aaa", nowMs: 1_710_000_000_000)
        guard case let .message(message, envelope) = WireCodec.decode(text) else {
            Issue.record("expected a message, got \(WireCodec.decode(text) as Any)")
            return
        }
        guard case let .hello(decoded) = message else {
            Issue.record("expected hello, got \(message.type)")
            return
        }
        #expect(decoded == info)
        #expect(envelope.from == "aaa")
        #expect(envelope.ts == 1_710_000_000_000)
        #expect(envelope.version == 1)
    }

    @Test
    func pongCarriesReplyTo() throws {
        let text = try WireCodec.encode(.pong, from: "aaa", nowMs: 5, replyTo: "ping-1")
        guard case let .message(message, envelope) = WireCodec.decode(text) else {
            Issue.record("expected a message")
            return
        }
        #expect(message.type == "pong")
        #expect(envelope.replyTo == "ping-1")
    }

    @Test
    func pongWithoutReplyToIsMalformed() {
        let replyToLessPong = "{\"v\":1,\"type\":\"pong\",\"id\":\"x\",\"from\":\"aaa\",\"ts\":1}"
        guard case let .malformed(reason, type) = WireCodec.decode(replyToLessPong) else {
            Issue.record("expected malformed for replyTo-less pong")
            return
        }
        #expect(type == "pong")
        #expect(reason.contains("replyTo"))
    }

    @Test
    func stateUpdateRoundTripWithArtistExtension() throws {
        let state = PresencePlaybackState(track: "Song", status: .playing, positionSec: 42.5, seq: 17, artist: "Artist")
        let text = try WireCodec.encode(.stateUpdate(state), from: "aaa", nowMs: 1)
        guard case let .message(.stateUpdate(decoded), _) = WireCodec.decode(text) else {
            Issue.record("expected state_update")
            return
        }
        #expect(decoded == state)
        // The extension field must actually be on the wire for older receivers
        // to ignore.
        #expect(text.contains("\"artist\":\"Artist\""))
    }

    @Test
    func stateUpdateRoundTripWithPlaybackModes() throws {
        // Playback-mode extension (protocol 2026-11-02).
        let state = PresencePlaybackState(
            track: "Song", status: .playing, positionSec: 1, seq: 3, shuffle: true, repeat: .one
        )
        let text = try WireCodec.encode(.stateUpdate(state), from: "aaa", nowMs: 1)
        guard case let .message(.stateUpdate(decoded), _) = WireCodec.decode(text) else {
            Issue.record("expected state_update")
            return
        }
        #expect(decoded == state)
        #expect(text.contains("\"shuffle\":true"))
        #expect(text.contains("\"repeat\":\"one\""))
    }

    @Test
    func stateUpdateWithoutModesOmitsKeysAndDecodesNil() throws {
        // Nil modes must not add new keys (byte-compatibility with old peers).
        let state = PresencePlaybackState(track: "Song", status: .paused, positionSec: 1, seq: 3)
        let text = try WireCodec.encode(.stateUpdate(state), from: "aaa", nowMs: 1)
        guard case let .message(.stateUpdate(decoded), _) = WireCodec.decode(text) else {
            Issue.record("expected state_update")
            return
        }
        #expect(decoded.shuffle == nil)
        #expect(decoded.repeat == nil)
        #expect(!text.contains("shuffle"))
        #expect(!text.contains("repeat"))
    }

    @Test
    func stateUpdateInvalidRepeatStringDecodesNil() {
        // Tolerant receiver: an unknown repeat value is dropped, never
        // malformed, never a disconnect.
        let json = "{\"v\":1,\"type\":\"state_update\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1," +
            "\"track\":\"T\",\"status\":\"playing\",\"positionSec\":3,\"seq\":2," +
            "\"shuffle\":true,\"repeat\":\"forever\"}"
        guard case let .message(.stateUpdate(state), _) = WireCodec.decode(json) else {
            Issue.record("expected state_update")
            return
        }
        #expect(state.shuffle == true)
        #expect(state.repeat == nil)
    }

    @Test
    func stateUpdateWithoutArtistDecodesNil() {
        let json = "{\"v\":1,\"type\":\"state_update\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1," +
            "\"track\":\"T\",\"status\":\"paused\",\"positionSec\":3,\"seq\":2}"
        guard case let .message(.stateUpdate(state), _) = WireCodec.decode(json) else {
            Issue.record("expected state_update")
            return
        }
        #expect(state.artist == nil)
        #expect(state.status == .paused)
        #expect(state.seq == 2)
    }

    @Test
    func stateUpdateMissingFieldsIsMalformed() {
        let json = "{\"v\":1,\"type\":\"state_update\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1,\"track\":\"T\",\"status\":\"playing\"}"
        guard case let .malformed(reason, type) = WireCodec.decode(json) else {
            Issue.record("expected malformed")
            return
        }
        #expect(type == "state_update")
        #expect(reason.contains("positionSec"))
    }

    @Test
    func stateUpdateBadStatusIsMalformed() {
        let json = "{\"v\":1,\"type\":\"state_update\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1," +
            "\"track\":\"T\",\"status\":\"rewinding\",\"positionSec\":3,\"seq\":2}"
        guard case .malformed = WireCodec.decode(json) else {
            Issue.record("expected malformed for unknown status")
            return
        }
    }

    @Test
    func unknownTypeIsReportedNotMalformed() {
        let json = "{\"v\":1,\"type\":\"future_thing\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1}"
        guard case let .unknownType(envelope) = WireCodec.decode(json) else {
            Issue.record("expected unknownType")
            return
        }
        #expect(envelope.type == "future_thing")
    }

    @Test
    func wrongVersionIsMalformed() {
        let json = "{\"v\":2,\"type\":\"ping\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1}"
        guard case .malformed = WireCodec.decode(json) else {
            Issue.record("expected malformed for v=2")
            return
        }
    }

    @Test
    func notJSONIsMalformed() {
        guard case .malformed = WireCodec.decode("hello there") else {
            Issue.record("expected malformed for non-JSON")
            return
        }
    }

    @Test
    func integerAndDoubleNumbersBothDecode() {
        // ts as an integer, positionSec as a bare integer (a peer that
        // serializes 17 instead of 17.0).
        let json = "{\"v\":1,\"type\":\"state_update\",\"id\":\"i\",\"from\":\"aaa\",\"ts\":1710000000000," +
            "\"track\":\"T\",\"status\":\"stopped\",\"positionSec\":17,\"seq\":2}"
        guard case let .message(.stateUpdate(state), envelope) = WireCodec.decode(json) else {
            Issue.record("expected state_update")
            return
        }
        #expect(envelope.ts == 1_710_000_000_000)
        #expect(state.positionSec == 17)
    }

    @Test
    func goodbyeAndTestRoundTrip() throws {
        let bye = try WireCodec.encode(.goodbye(reason: "app_shutdown"), from: "aaa", nowMs: 1)
        guard case let .message(.goodbye(reason), _) = WireCodec.decode(bye) else {
            Issue.record("expected goodbye")
            return
        }
        #expect(reason == "app_shutdown")

        let test = try WireCodec.encode(.test(text: "hi"), from: "aaa", nowMs: 1)
        guard case let .message(.test(text), _) = WireCodec.decode(test) else {
            Issue.record("expected test")
            return
        }
        #expect(text == "hi")
    }

    @Test
    func envelopeIDsAreLowercasedUUIDs() {
        let envelope = WireCodec.envelope(from: "aaa", nowMs: 1)
        #expect(UUID(uuidString: envelope.id) != nil)
        #expect(envelope.id == envelope.id.lowercased())
    }
}
