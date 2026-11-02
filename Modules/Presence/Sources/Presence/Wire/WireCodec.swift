import Foundation

/// Encodes and decodes the JSON envelope (one JSON text frame per message,
/// contract section 6) and applies the receiver rules: unknown `type` and
/// missing/invalid required fields are surfaced to the caller for logging and
/// ignored, never disconnecting.
public enum WireCodec {
    /// Frame keys are sorted so captures of the same logical message are stable.
    public static func encode(
        _ message: PresenceMessage,
        envelope: PresenceEnvelope
    ) throws -> String {
        var object: [String: Any] = [
            "v": envelope.version,
            "type": message.type,
            "id": envelope.id,
            "from": envelope.from,
            "ts": envelope.ts,
        ]
        if let replyTo = envelope.replyTo {
            object["replyTo"] = replyTo
        }
        switch message {
        case let .hello(info), let .helloAck(info):
            object["name"] = info.name
            object["platform"] = info.platform
            object["appVersion"] = info.appVersion

        case .ping, .pong:
            break

        case let .stateUpdate(state):
            Self.encodeStateUpdate(state, into: &object)

        case let .test(text):
            object["text"] = text

        case let .command(command):
            object["action"] = command.action
            if let position = command.positionSec {
                object["positionSec"] = position
            }

        case let .queue(queue):
            if let current = queue.current {
                object["current"] = current
            }
            if let hashes = queue.hashes {
                object["hashes"] = hashes
            }

        case let .goodbye(reason):
            object["reason"] = reason
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    /// Builds an envelope with a fresh UUID message id (UUID v4, lowercased) and
    /// the sender's clock. Callers that need the id (ping bookkeeping) build the
    /// envelope first and encode with it.
    public static func envelope(
        from senderID: String,
        nowMs: Double,
        replyTo: String? = nil,
        version: Int = 1
    ) -> PresenceEnvelope {
        PresenceEnvelope(
            version: version,
            type: "",
            id: UUID().uuidString.lowercased(),
            from: senderID,
            ts: nowMs,
            replyTo: replyTo
        )
    }

    /// Builds an envelope with a fresh UUID message id (UUID v4, lowercased) and
    /// the sender's clock, then encodes.
    public static func encode(
        _ message: PresenceMessage,
        from senderID: String,
        nowMs: Double,
        replyTo: String? = nil,
        version: Int = 1
    ) throws -> String {
        let envelope = Self.envelope(from: senderID, nowMs: nowMs, replyTo: replyTo, version: version)
        return try Self.encode(message, envelope: envelope)
    }

    /// Decodes one text frame. Never throws: every failure mode is a receiver
    /// rule (malformed -> ignore, unknown type -> ignore) or a `nil` for
    /// not-a-JSON-object.
    public static func decode(_ text: String) -> DecodedPresenceFrame? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .malformed(reason: "not a JSON object", type: nil)
        }

        var missing: [String] = []
        let version = Self.int(object["v"])
        if version != 1 {
            missing.append("v")
        }
        let type = object["type"] as? String
        if type == nil {
            missing.append("type")
        }
        let id = object["id"] as? String
        if id == nil {
            missing.append("id")
        }
        let from = object["from"] as? String
        if from == nil {
            missing.append("from")
        }
        let ts = Self.double(object["ts"])
        if ts == nil {
            missing.append("ts")
        }
        if !missing.isEmpty {
            return .malformed(reason: "missing/invalid fields: \(missing.joined(separator: ","))", type: type)
        }

        let envelope = PresenceEnvelope(
            version: version ?? 0,
            type: type ?? "",
            id: id ?? "",
            from: from ?? "",
            ts: ts ?? 0,
            replyTo: object["replyTo"] as? String
        )
        return Self.decodePayload(object, envelope: envelope)
    }

    private static func decodeHello(_ object: [String: Any], envelope: PresenceEnvelope) -> DecodedPresenceFrame {
        guard let name = object["name"] as? String,
              object["platform"] != nil,
              object["appVersion"] != nil else {
            return .malformed(reason: "missing name/platform/appVersion", type: envelope.type)
        }
        let info = PresenceHelloInfo(
            name: name,
            platform: object["platform"] as? String ?? "",
            appVersion: object["appVersion"] as? String ?? ""
        )
        return envelope.type == "hello" ? .message(.hello(info), envelope: envelope)
            : .message(.helloAck(info), envelope: envelope)
    }

    private static func decodePayload(_ object: [String: Any], envelope: PresenceEnvelope) -> DecodedPresenceFrame {
        switch envelope.type {
        case "hello", "hello_ack":
            return Self.decodeHello(object, envelope: envelope)

        case "ping":
            return .message(.ping, envelope: envelope)

        case "pong":
            guard envelope.replyTo != nil else {
                return .malformed(reason: "pong without replyTo", type: envelope.type)
            }
            return .message(.pong, envelope: envelope)

        case "state_update":
            return Self.decodeStateUpdate(object, envelope: envelope)

        case "test":
            return .message(.test(text: object["text"] as? String ?? ""), envelope: envelope)

        case "command":
            guard let action = object["action"] as? String else {
                return .malformed(reason: "command without action", type: envelope.type)
            }
            let command = PresenceCommand(
                action: action,
                positionSec: Self.double(object["positionSec"])
            )
            return .message(.command(command), envelope: envelope)

        case "queue":
            return Self.decodeQueue(object, envelope: envelope)

        case "goodbye":
            let reason = object["reason"] as? String
            guard let reason else {
                return .malformed(reason: "goodbye without reason", type: envelope.type)
            }
            return .message(.goodbye(reason: reason), envelope: envelope)

        default:
            return .unknownType(envelope)
        }
    }

    /// The `state_update` payload fields (contract section 6): extension
    /// fields are encoded only when present (no new keys when nil).
    private static func encodeStateUpdate(_ state: PresencePlaybackState, into object: inout [String: Any]) {
        object["track"] = state.track
        if let artist = state.artist {
            object["artist"] = artist
        }
        object["status"] = state.status.rawValue
        object["positionSec"] = state.positionSec
        object["seq"] = state.seq
        if let trackHash = state.trackHash {
            object["trackHash"] = trackHash
        }
        if let playbackId = state.playbackId {
            object["playbackId"] = playbackId
        }
        if let shuffle = state.shuffle {
            object["shuffle"] = shuffle
        }
        if let repeatMode = state.repeat {
            object["repeat"] = repeatMode.rawValue
        }
    }

    /// The `state_update` required fields are malformed when missing
    /// (contract section 6); the optional extension fields decode tolerantly.
    private static func decodeStateUpdate(_ object: [String: Any], envelope: PresenceEnvelope) -> DecodedPresenceFrame {
        guard let track = object["track"] as? String,
              let statusRaw = object["status"] as? String,
              let status = PresenceStatus(rawValue: statusRaw),
              let position = double(object["positionSec"]),
              let seq = int(object["seq"]) else {
            return .malformed(reason: "missing/invalid track|status|positionSec|seq", type: envelope.type)
        }
        let state = PresencePlaybackState(
            track: track,
            status: status,
            positionSec: position,
            seq: seq,
            artist: object["artist"] as? String,
            trackHash: object["trackHash"] as? String,
            playbackId: object["playbackId"] as? String,
            shuffle: object["shuffle"] as? Bool,
            repeat: (object["repeat"] as? String).flatMap(PresenceRepeatMode.init(rawValue:))
        )
        return .message(.stateUpdate(state), envelope: envelope)
    }

    /// Lenient `queue` decode (contract section 9): an absent `hashes` key is
    /// an empty array (valid), while a non-array or non-string-entry array is
    /// surfaced as nil for the engine's malformed log; `current` is
    /// normalized at the engine.
    private static func decodeQueue(_ object: [String: Any], envelope: PresenceEnvelope) -> DecodedPresenceFrame {
        let hashes: [String]?
        if object["hashes"] == nil {
            hashes = []
        } else {
            hashes = object["hashes"] as? [String]
        }
        let message = PresenceQueueMessage(
            current: Self.int(object["current"]),
            hashes: hashes
        )
        return .message(.queue(message), envelope: envelope)
    }

    /// JSONSerialization hands integers back as NSNumber bridged to `Int`, but
    /// peers that serialize `17.0` produce a `Double`; accept both.
    private static func int(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let double = value as? Double, double == double.rounded() {
            return Int(double)
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        return nil
    }
}
