import Foundation

/// Which socket stack the engine uses. `.networkFramework` is the primary
/// NWListener/NWBrowser/NWConnection stack; `.bsdSocket` is the POSIX
/// listener + NetService discovery + BSD WebSocket transport fallback; the
/// default `.automatic` runs NW and falls back to BSD when the NW listen path
/// fails within the startup probe window.
public enum PresenceTransportStack: Sendable, Equatable {
    case networkFramework
    case bsdSocket
    case automatic
}

/// Wire and timing tunables for the Presence protocol. Every default is the
/// frozen contract value (docs/design-spec/PROTOCOL.md); tests inject tighter
/// values to keep suites fast.
public struct PresenceConfig: Sendable {
    /// mDNS service type (`_musicshare._tcp`, contract section 2).
    public let serviceType: String
    /// Protocol version advertised in the TXT `v` field and the envelope `v`.
    public let protocolVersion: Int
    /// Seconds between keepalive pings (contract section 4).
    public let pingInterval: TimeInterval
    /// Seconds after the last pong before a peer is judged dead (section 4).
    public let pongTimeout: TimeInterval
    /// Seconds from socket open within which the handshake must finish (section 3).
    public let handshakeTimeout: TimeInterval
    /// Seconds from dial start within which the socket must open (section 3
    /// handshake budget; a dead peer's backlog otherwise parks the dial forever).
    public let dialTimeout: TimeInterval
    /// Seconds without a re-announcement after which a socket-less discovered
    /// peer expires (section 2). Connected peers are exempt.
    public let peerExpiry: TimeInterval
    /// Seconds an mDNS removal hint is held before it may mark a peer gone
    /// (churn defense; the peer is kept if it reappears inside the window).
    public let removalDebounce: TimeInterval
    /// Maximum age (seconds) of the last pong for a connection to count as
    /// healthy in the discovery-hint guard: a CONNECTED socket with fresh
    /// pongs is never torn down from a discovery hint alone.
    public let healthyPongAge: TimeInterval
    /// Seconds between engine housekeeping ticks (deadline checks, dials, expiry).
    public let tickInterval: TimeInterval
    /// Seconds between fresh mDNS browse passes. NWBrowser only reports set
    /// changes, so a periodic re-browse is what refreshes peer announcements
    /// and keeps the 60 s expiry honest (must stay well under peerExpiry).
    public let rebrowseInterval: TimeInterval
    /// Shared session (section 8): seconds two-or-more playing devices may
    /// overlap before a device reports `session_conflict` (the legal takeover
    /// handoff grace). Never auto-resolved.
    public let sessionConflictGrace: TimeInterval
    /// Reconnect ladder (section 5).
    public let backoff: BackoffSchedule
    /// Whether the engine registers with and browses mDNS. Loopback tests run
    /// with both off and dial by address.
    public let usesDiscovery: Bool
    /// Whether `start()` binds the WebSocket listener. In-memory protocol
    /// tests run without one and drive transports directly; every real
    /// deployment binds.
    public let bindsListener: Bool
    /// The socket stack (see `PresenceTransportStack`).
    public let transportStack: PresenceTransportStack
    /// The Bonjour service instance name. Distinct per instance in tests.
    public let advertiseName: String?

    public init(
        serviceType: String = "_musicshare._tcp",
        protocolVersion: Int = 1,
        pingInterval: TimeInterval = 5,
        pongTimeout: TimeInterval = 10,
        handshakeTimeout: TimeInterval = 5,
        dialTimeout: TimeInterval = 5,
        peerExpiry: TimeInterval = 60,
        removalDebounce: TimeInterval = 2.5,
        healthyPongAge: TimeInterval = 15,
        tickInterval: TimeInterval = 1,
        rebrowseInterval: TimeInterval = 45,
        backoff: BackoffSchedule = .default,
        usesDiscovery: Bool = true,
        bindsListener: Bool = true,
        transportStack: PresenceTransportStack = .automatic,
        sessionConflictGrace: TimeInterval = 2.0,
        advertiseName: String? = nil
    ) {
        self.serviceType = serviceType
        self.protocolVersion = protocolVersion
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.handshakeTimeout = handshakeTimeout
        self.dialTimeout = dialTimeout
        self.peerExpiry = peerExpiry
        self.removalDebounce = removalDebounce
        self.healthyPongAge = healthyPongAge
        self.tickInterval = tickInterval
        self.rebrowseInterval = rebrowseInterval
        self.backoff = backoff
        self.usesDiscovery = usesDiscovery
        self.bindsListener = bindsListener
        self.transportStack = transportStack
        self.sessionConflictGrace = sessionConflictGrace
        self.advertiseName = advertiseName
    }

    public static let `default` = Self()
}
