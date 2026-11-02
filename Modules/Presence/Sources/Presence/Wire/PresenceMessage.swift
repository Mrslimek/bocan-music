import Foundation

// MARK: - Value types

/// Playback status on the wire (contract section 6: playing | paused | stopped).
public enum PresenceStatus: String, Sendable, Equatable, CaseIterable {
    case playing
    case paused
    case stopped
}

/// The queue repeat mode on the wire (contract section 6, playback-mode
/// extension added 2026-11-02).
public enum PresenceRepeatMode: String, Sendable, Equatable, CaseIterable {
    case off
    case all
    case one
}

/// The flattened payload of a `state_update`: what a peer is playing right now.
/// `artist` is a Bòcan extension field; receivers must ignore unknown fields,
/// and peers that do not send one leave it nil.
public struct PresencePlaybackState: Sendable, Equatable {
    public var track: String
    public var artist: String?
    public var status: PresenceStatus
    public var positionSec: Double
    /// Per-device monotonic counter, starts at 1 each app run, +1 per state change.
    public var seq: Int
    /// Shared session (contract section 8): lowercase-hex SHA-256 of the
    /// audio file's bytes. Absent = the peer does not participate in the
    /// session extension.
    public var trackHash: String?
    /// UUID v4 of one continuous playback stint: fresh on every track start
    /// and every takeover; a pause-to-resume of the same stint keeps it.
    public var playbackId: String?
    /// Playback-mode extension (contract section 6, added 2026-11-02): the
    /// sender's queue modes. Absent = the peer does not report them.
    public var shuffle: Bool?
    public var `repeat`: PresenceRepeatMode?

    public init(
        track: String,
        status: PresenceStatus,
        positionSec: Double,
        seq: Int,
        artist: String? = nil,
        trackHash: String? = nil,
        playbackId: String? = nil,
        shuffle: Bool? = nil,
        repeat: PresenceRepeatMode? = nil
    ) {
        self.track = track
        self.artist = artist
        self.status = status
        self.positionSec = positionSec
        self.seq = seq
        self.trackHash = trackHash
        self.playbackId = playbackId
        self.shuffle = shuffle
        self.repeat = `repeat`
    }

    public static let empty = Self(track: "", status: .stopped, positionSec: 0, seq: 0)
}

/// A remote playback control action (contract section 6, `command`).
public enum PresenceCommandAction: String, Sendable, Equatable, CaseIterable {
    case play
    case pause
    case toggle
    case stop
    case seek
    case next
    case previous
    // Playback-mode extension (contract section 6, added 2026-11-02).
    case repeatOff = "repeat_off"
    case repeatAll = "repeat_all"
    case repeatOne = "repeat_one"
    case shuffleOn = "shuffle_on"
    case shuffleOff = "shuffle_off"
}

/// A decoded `queue` message (contract section 9, added 2026-11-02): the
/// sender's playback queue as an ordered array of lowercase-hex SHA-256 track
/// hashes, plus the 0-based index of the currently-playing entry (nil when
/// nothing in the array is playing). `hashes` is left unvalidated at the type
/// level so the engine owns the tolerant-receiver malformed decision.
public struct PresenceQueueMessage: Sendable, Equatable {
    public let current: Int?
    /// nil means the payload was not a valid string array (absent key, non-array,
    /// or non-string entries) — the engine logs `message_malformed`.
    public let hashes: [String]?

    public init(current: Int?, hashes: [String]?) {
        self.current = current
        self.hashes = hashes
    }
}

/// A decoded `command` message. `action` keeps the wire string so foreign
/// peers sending unknown actions surface as `command_ignored
/// reason=unsupported` instead of malformed frames; `positionSec` is required
/// by the contract for `seek` (enforced by the engine) and ignored otherwise.
public struct PresenceCommand: Sendable, Equatable {
    public let action: String
    public let positionSec: Double?

    public init(action: String, positionSec: Double? = nil) {
        self.action = action
        self.positionSec = positionSec
    }
}

/// The identity fields carried by `hello` / `hello_ack` (contract section 6).
public struct PresenceHelloInfo: Sendable, Equatable {
    public var name: String
    public var platform: String
    public var appVersion: String

    public init(name: String, platform: String, appVersion: String) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// One protocol message, decoded out of the envelope. `ping`/`pong` carry the
/// envelope only; `pong` adds `replyTo`.
public enum PresenceMessage: Sendable, Equatable {
    case hello(PresenceHelloInfo)
    case helloAck(PresenceHelloInfo)
    case ping
    case pong
    case stateUpdate(PresencePlaybackState)
    case test(text: String)
    case command(PresenceCommand)
    case queue(PresenceQueueMessage)
    case goodbye(reason: String)

    public var type: String {
        switch self {
        case .hello:
            "hello"

        case .helloAck:
            "hello_ack"

        case .ping:
            "ping"

        case .pong:
            "pong"

        case .stateUpdate:
            "state_update"

        case .test:
            "test"

        case .command:
            "command"

        case .queue:
            "queue"

        case .goodbye:
            "goodbye"
        }
    }
}

/// The common envelope fields (contract section 6).
public struct PresenceEnvelope: Sendable, Equatable {
    /// Protocol version; always 1.
    public let version: Int
    public let type: String
    public let id: String
    public let from: String
    /// Sender clock, unix milliseconds. Informational only (contract section 4).
    public let ts: Double
    /// The id of the message this one answers, when applicable.
    public let replyTo: String?

    public init(version: Int, type: String, id: String, from: String, ts: Double, replyTo: String? = nil) {
        self.version = version
        self.type = type
        self.id = id
        self.from = from
        self.ts = ts
        self.replyTo = replyTo
    }
}

/// The three receiver-rule outcomes (contract section 6): a known message, an
/// unknown type (ignore, keep connected), or a malformed frame (ignore).
public enum DecodedPresenceFrame: Sendable, Equatable {
    case message(PresenceMessage, envelope: PresenceEnvelope)
    case unknownType(PresenceEnvelope)
    case malformed(reason: String, type: String?)
}
