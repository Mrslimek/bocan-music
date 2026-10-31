import CryptoKit
import Foundation

// MARK: - Frame types

/// One raw RFC 6455 frame. `opcode` is the wire opcode (0x0 continuation,
/// 0x1 text, 0x2 binary, 0x8 close, 0x9 ping, 0xA pong).
public struct WSFrame: Equatable, Sendable {
    public let fin: Bool
    public let opcode: UInt8
    public let payload: Data

    public init(fin: Bool, opcode: UInt8, payload: Data) {
        self.fin = fin
        self.opcode = opcode
        self.payload = payload
    }
}

public enum WSFrameResult: Equatable, Sendable {
    case needMore
    case oversize
    case frame(WSFrame)
}

/// Inbound application events assembled out of frames by `WSMessageAssembler`.
public enum WSInboundEvent: Equatable, Sendable {
    case text(String)
    case close(code: UInt16, reason: String)
    case ping(payload: Data)
    case pong(payload: Data)
}

public enum WSInboundOutcome: Equatable, Sendable {
    case needMore
    case event(WSInboundEvent)
    case invalid(String)
}

// MARK: - Frame codec

/// Minimal RFC 6455 frame codec. Outgoing frames are masked when `mask` is
/// set (clients mask, servers do not); incoming frames are unmasked whenever
/// the wire mask bit says so, so client and server frames decode through one
/// path. Message reassembly lives in `WSMessageAssembler`.
public enum WSFrameCodec {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Hard frame-size cap (1 MiB) for the receive path.
    public static let maxPayload = 1 << 20

    /// Control frames (close, ping, pong) are opcode 0x8-0xF.
    public static func isControl(_ opcode: UInt8) -> Bool {
        opcode & 0x8 != 0
    }

    /// Serializes one frame; `mask` applies a fresh random masking key
    /// (clients mask, servers do not).
    public static func encode(frame: WSFrame, mask: Bool) -> Data {
        var out = Data()
        out.append(frame.fin ? 0x80 | frame.opcode : frame.opcode)
        let count = frame.payload.count
        let maskBit: UInt8 = mask ? 0x80 : 0x00
        if count < 126 {
            out.append(maskBit | UInt8(count))
        } else if count <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(count >> 8))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((UInt64(count) >> shift) & 0xFF))
            }
        }
        if mask {
            let key = (0..<4).map { _ in UInt8.random(in: 0...255) }
            out.append(contentsOf: key)
            out.append(contentsOf: frame.payload.enumerated().map { index, byte in
                byte ^ key[index % 4]
            })
        } else {
            out.append(contentsOf: frame.payload)
        }
        return out
    }

    /// Decodes one frame from the front of `buffer`, consuming its bytes on
    /// success. The wire mask bit drives unmasking, so client and server
    /// frames decode through the same path.
    public static func decode(_ buffer: inout Data, maxPayload: Int = Self.maxPayload) -> WSFrameResult {
        switch Self.readHeader(buffer) {
        case .needMore:
            return .needMore

        case .oversize:
            return .oversize

        case let .header(header):
            guard header.length <= maxPayload else { return .oversize }
            return Self.readBody(&buffer, header: header)
        }
    }

    /// One parsed frame header: `bodyStart` is where the payload begins
    /// (mask bytes already skipped).
    private struct FrameHeader: Equatable {
        let fin: Bool
        let opcode: UInt8
        let length: Int
        let bodyStart: Int
    }

    private enum ParsedHeader {
        case needMore
        case oversize
        case header(FrameHeader)
    }

    private static func readHeader(_ buffer: Data) -> ParsedHeader {
        guard buffer.count >= 2 else { return .needMore }
        let first = buffer[buffer.startIndex]
        let second = buffer[buffer.startIndex + 1]
        let fin = first & 0x80 != 0
        let opcode = first & 0x0F
        let masked = second & 0x80 != 0
        var length = Int(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return .needMore }
            length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return .needMore }
            var extended: UInt64 = 0
            for index in 0..<8 {
                extended = extended << 8 | UInt64(buffer[buffer.startIndex + 2 + index])
            }
            guard extended <= UInt64(Int.max) else { return .oversize }
            length = Int(extended)
            offset = 10
        }
        if masked {
            guard buffer.count >= offset + 4 else { return .needMore }
            offset += 4
        }
        guard buffer.count >= offset + length else { return .needMore }
        return .header(FrameHeader(fin: fin, opcode: opcode, length: length, bodyStart: offset))
    }

    private static func readBody(_ buffer: inout Data, header: FrameHeader) -> WSFrameResult {
        let masked = buffer[buffer.startIndex + 1] & 0x80 != 0
        let fin = header.fin
        let opcode = header.opcode
        let length = header.length
        let bodyStart = header.bodyStart
        var maskKey: [UInt8] = []
        if masked {
            maskKey = [UInt8](buffer[
                buffer.index(buffer.startIndex, offsetBy: bodyStart - 4)
                    ..< buffer.index(buffer.startIndex, offsetBy: bodyStart)
            ])
        }
        let start = buffer.index(buffer.startIndex, offsetBy: bodyStart)
        let end = buffer.index(start, offsetBy: length)
        var payload = Data(buffer[start..<end])
        if masked {
            for index in 0..<payload.count {
                payload[index] ^= maskKey[index % 4]
            }
        }
        buffer.removeSubrange(buffer.startIndex..<end)
        return .frame(WSFrame(fin: fin, opcode: opcode, payload: payload))
    }

    /// The `Sec-WebSocket-Accept` value for a handshake key (RFC 6455 section 4.2.2).
    public static func acceptHeader(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let digest = Insecure.SHA1.hash(data: Data((key + Self.guid).utf8))
        return Data(digest).base64EncodedString()
    }
}

// MARK: - Message assembler

/// Reassembles fragmented messages and maps control frames onto inbound
/// events, per RFC 6455 section 5.4: control frames may be interleaved with a
/// fragmented message and must never themselves be fragmented. Only text data
/// messages exist in this protocol.
public struct WSMessageAssembler: Sendable, Equatable {
    private var messageOpcode: UInt8?
    private var messagePayload = Data()

    public init() {}

    public mutating func ingest(_ frame: WSFrame) -> WSInboundOutcome {
        if WSFrameCodec.isControl(frame.opcode) {
            return self.ingestControl(frame)
        }
        return self.ingestData(frame)
    }

    private func ingestControl(_ frame: WSFrame) -> WSInboundOutcome {
        guard frame.fin else {
            return .invalid("fragmented control frame")
        }
        switch frame.opcode {
        case 0x8:
            var code: UInt16 = 1005
            if frame.payload.count >= 2 {
                code = UInt16(frame.payload[frame.payload.startIndex]) << 8
                    | UInt16(frame.payload[frame.payload.startIndex + 1])
            }
            let reason = frame.payload.count > 2
                ? String(bytes: frame.payload.dropFirst(2), encoding: .utf8) ?? "" : ""
            return .event(.close(code: code, reason: reason))

        case 0x9:
            return .event(.ping(payload: frame.payload))

        case 0xA:
            return .event(.pong(payload: frame.payload))

        default:
            return .invalid("unexpected control opcode \(frame.opcode)")
        }
    }

    private mutating func ingestData(_ frame: WSFrame) -> WSInboundOutcome {
        if frame.opcode == 0x0 {
            guard self.messageOpcode != nil else {
                return .invalid("continuation without a message")
            }
            self.messagePayload.append(frame.payload)
        } else if self.messageOpcode != nil {
            return .invalid("new data frame inside a fragmented message")
        } else if frame.opcode != 0x1 {
            return .invalid("unexpected data opcode \(frame.opcode)")
        } else if frame.fin {
            return Self.decodeText(payload: frame.payload)
        } else {
            self.messageOpcode = frame.opcode
            self.messagePayload = frame.payload
            return .needMore
        }

        guard frame.fin else { return .needMore }
        let payload = self.messagePayload
        self.messageOpcode = nil
        self.messagePayload = Data()
        return Self.decodeText(payload: payload)
    }

    private static func decodeText(payload: Data) -> WSInboundOutcome {
        guard let text = String(bytes: payload, encoding: .utf8) else {
            return .invalid("invalid utf-8 text frame")
        }
        return .event(.text(text))
    }
}
