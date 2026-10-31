import Foundation
import Testing

@testable import Presence

// MARK: - RFC 6455 frame codec and message assembler

@Suite
struct WSFrameCodecTests {
    private static func maskedClientFrame(_ text: String) -> Data {
        WSFrameCodec.encode(frame: WSFrame(fin: true, opcode: 0x1, payload: Data(text.utf8)), mask: true)
    }

    @Test
    func unmaskedRoundTrip() {
        let frame = WSFrame(fin: true, opcode: 0x1, payload: Data("hello peer".utf8))
        var buffer = WSFrameCodec.encode(frame: frame, mask: false)
        guard case let .frame(decoded) = WSFrameCodec.decode(&buffer) else {
            Issue.record("expected a frame")
            return
        }
        #expect(decoded == frame)
        #expect(buffer.isEmpty)
    }

    @Test
    func maskedClientFrameDecodesToPlainPayload() {
        // A client masks its frames; the server side must recover the payload
        // through the frame's mask bit, with a fresh random key every time.
        let text = "state_update json on the wire"
        for _ in 0..<20 {
            var buffer = Self.maskedClientFrame(text)
            guard case let .frame(decoded) = WSFrameCodec.decode(&buffer) else {
                Issue.record("expected a frame")
                return
            }
            #expect(decoded.fin)
            #expect(decoded.opcode == 0x1)
            #expect(String(bytes: decoded.payload, encoding: .utf8) == text)
            #expect(buffer.isEmpty)
        }
    }

    @Test
    func extendedSixteenBitLengthDecodes() {
        let payload = Data(repeating: 0x41, count: 300)
        let frame = WSFrame(fin: true, opcode: 0x1, payload: payload)
        var buffer = WSFrameCodec.encode(frame: frame, mask: true)
        guard case let .frame(decoded) = WSFrameCodec.decode(&buffer) else {
            Issue.record("expected a frame")
            return
        }
        #expect(decoded.payload == payload)
    }

    @Test
    func partialFrameNeedsMore() {
        var buffer = Self.maskedClientFrame("abc")
        // Drop the tail: the header alone must not decode.
        buffer.removeLast(2)
        guard case .needMore = WSFrameCodec.decode(&buffer) else {
            Issue.record("expected needMore for a truncated frame")
            return
        }
        // A single header byte is not enough either.
        var oneByte = buffer
        oneByte.removeLast()
        guard case .needMore = WSFrameCodec.decode(&oneByte) else {
            Issue.record("expected needMore for a header byte")
            return
        }
    }

    @Test
    func oversizedFrameIsRejected() {
        let frame = WSFrame(fin: true, opcode: 0x1, payload: Data(repeating: 0, count: 64))
        var buffer = WSFrameCodec.encode(frame: frame, mask: true)
        guard case .oversize = WSFrameCodec.decode(&buffer, maxPayload: 32) else {
            Issue.record("expected oversize")
            return
        }
    }

    @Test
    func acceptHeaderMatchesRFC6455Vector() {
        // The RFC's own test vector (section 1.3).
        let accept = WSFrameCodec.acceptHeader(for: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    // MARK: Assembler

    @Test
    func assemblerYieldsTextAndPongAndClose() {
        var assembler = WSMessageAssembler()
        let text = WSFrame(fin: true, opcode: 0x1, payload: Data("hi".utf8))
        let ping = WSFrame(fin: true, opcode: 0x9, payload: Data([1, 2]))
        let close = WSFrame(fin: true, opcode: 0x8, payload: Data([0x03, 0xE8]) + Data("bye".utf8))

        guard case let .event(.text(text: received)) = assembler.ingest(text) else {
            Issue.record("expected text")
            return
        }
        #expect(received == "hi")

        guard case let .event(.ping(payload)) = assembler.ingest(ping) else {
            Issue.record("expected ping")
            return
        }
        #expect(payload == Data([1, 2]))

        guard case let .event(.close(code, reason)) = assembler.ingest(close) else {
            Issue.record("expected close")
            return
        }
        #expect(code == 1000)
        #expect(reason == "bye")
    }

    @Test
    func fragmentedTextReassemblesAndPermitsInterleavedPing() {
        var assembler = WSMessageAssembler()
        let part1 = WSFrame(fin: false, opcode: 0x1, payload: Data("Hel".utf8))
        let ping = WSFrame(fin: true, opcode: 0x9, payload: Data())
        let part2 = WSFrame(fin: false, opcode: 0x0, payload: Data("lo ".utf8))
        let part3 = WSFrame(fin: true, opcode: 0x0, payload: Data("peer".utf8))

        guard case .needMore = assembler.ingest(part1) else {
            Issue.record("expected needMore after part 1")
            return
        }
        // Control frames may interleave with a fragmented message.
        guard case .event(.ping) = assembler.ingest(ping) else {
            Issue.record("expected the interleaved ping")
            return
        }
        guard case .needMore = assembler.ingest(part2) else {
            Issue.record("expected needMore after part 2")
            return
        }
        guard case let .event(.text(received)) = assembler.ingest(part3) else {
            Issue.record("expected the completed message")
            return
        }
        #expect(received == "Hello peer")
    }

    @Test
    func assemblerRejectsProtocolViolations() {
        var assembler = WSMessageAssembler()
        // Continuation with no message in flight.
        guard case .invalid = assembler.ingest(WSFrame(fin: true, opcode: 0x0, payload: Data())) else {
            Issue.record("expected invalid continuation")
            return
        }
        // Fragmented control frame.
        guard case .invalid = assembler.ingest(WSFrame(fin: false, opcode: 0x9, payload: Data())) else {
            Issue.record("expected invalid fragmented control frame")
            return
        }
        // A new text frame while a fragmented message is open.
        _ = assembler.ingest(WSFrame(fin: false, opcode: 0x1, payload: Data("a".utf8)))
        guard case .invalid = assembler.ingest(WSFrame(fin: true, opcode: 0x1, payload: Data("b".utf8))) else {
            Issue.record("expected invalid interleaved data frame")
            return
        }
    }

    @Test
    func closeWithoutPayloadDefaultsTo1005() {
        var assembler = WSMessageAssembler()
        guard case let .event(.close(code, reason)) = assembler.ingest(
            WSFrame(fin: true, opcode: 0x8, payload: Data())
        ) else {
            Issue.record("expected close")
            return
        }
        #expect(code == 1005)
        #expect(reason.isEmpty)
    }
}
