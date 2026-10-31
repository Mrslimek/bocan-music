import Foundation
import Network
import Observability
import os

/// Owns the WebSocket listener for the engine, on either socket stack.
///
/// Primary: `NWListener` with `NWProtocolWebSocket` options and the Bonjour
/// registration riding on it (one lifecycle for port and advertisement),
/// browsing via `NWBrowser`, dials via `NWConnection`. Fallback (macOS 27.2
/// measured, ADR-097 amendment): where the NW listen path fails at startup,
/// a POSIX `BSDWSServer` takes over and advertising/discovery move to
/// Foundation `NetService`. The fallback engages on the startup probe only;
/// on healthy systems NW keeps the clean stack.
public actor PresenceListener {
    /// The Bonjour service type (canonical trailing-dot form).
    static let canonicalServiceType = "_musicshare._tcp."

    /// How long the NW listener gets to reach `.ready` before the `.automatic`
    /// probe gives up and falls back to the BSD stack.
    static let startupProbeWindow: TimeInterval = 2

    /// Which stack actually serves after `start` (differs from the configured
    /// one only under `.automatic` when the NW probe failed).
    public private(set) var effectiveStack: PresenceTransportStack = .networkFramework

    private let configuredStack: PresenceTransportStack
    private let queue = DispatchQueue(label: "io.cloudcauldron.bocan.presence.listener")
    private let log = AppLogger.make(.presence)

    private var listener: NWListener?
    private var permissionBrowser: NWBrowser?
    private var bsdServer: BSDWSServer?
    private var netService: NetServicePresence?
    private var advertising = false
    private var pendingServiceName: String?
    private var pendingTXT: [(String, String)] = []

    /// The bound port, or nil while stopped.
    public private(set) var port: UInt16?

    /// Called for every accepted connection as a ready-to-own `WSTransport`
    /// (the engine wraps it in a `PeerConnection`, callee role).
    private var onConnection: (@Sendable (WSTransport) -> Void)?

    /// Installs the accept handler before `start` (isolated mutation).
    public func setAcceptHandler(_ handler: @escaping @Sendable (WSTransport) -> Void) {
        self.onConnection = handler
    }

    /// - Parameter configuredStack: the stack selection (default automatic).
    public init(configuredStack: PresenceTransportStack = .automatic) {
        self.configuredStack = configuredStack
    }

    /// The contract TXT record: persistent device id, display name, protocol v.
    public static func txtRecord(id: String, name: String, version: Int) -> NWTXTRecord {
        NWTXTRecord(["id": id, "name": name, "v": String(version)])
    }

    static func txtPairs(id: String, name: String, version: Int) -> [(String, String)] {
        [("id", id), ("name", name), ("v", String(version))]
    }

    // MARK: Start

    /// Binds on an ephemeral port and, when `advertise` is true, registers the
    /// Bonjour service with the contract TXT record (id/name/v). Returns the
    /// actual bound port. Under `.automatic` an NW failure within the probe
    /// window tears the NW listener down and starts the BSD stack.
    public func start(advertise: Bool, serviceName: String, txt: NWTXTRecord) async throws -> UInt16 {
        self.advertising = advertise
        self.pendingServiceName = serviceName
        self.pendingTXT = Self.txtPairs(
            id: txt["id"] ?? "",
            name: txt["name"] ?? serviceName,
            version: Int(txt["v"] ?? "") ?? 1
        )

        switch self.configuredStack {
        case .networkFramework:
            self.effectiveStack = .networkFramework
            return try await self.startNW(advertise: advertise, serviceName: serviceName, txt: txt)

        case .bsdSocket:
            self.effectiveStack = .bsdSocket
            return try await self.startBSD(advertise: advertise)

        case .automatic:
            do {
                let port = try await self.startNW(advertise: advertise, serviceName: serviceName, txt: txt)
                self.effectiveStack = .networkFramework
                return port
            } catch {
                self.log.warning("presence.listener.fallback", [
                    "error": String(reflecting: error),
                    "to": "bsd",
                ])
                self.tearDownNW()
                self.effectiveStack = .bsdSocket
                return try await self.startBSD(advertise: advertise)
            }
        }
    }

    // MARK: NW stack (primary)

    private func startNW(advertise: Bool, serviceName: String, txt: NWTXTRecord) async throws -> UInt16 {
        let listener = try NWListener(using: WSParameters.make(), on: .any)
        self.listener = listener
        if advertise {
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.canonicalServiceType,
                txtRecord: txt
            )
        }

        let accepted = self.onConnection
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            accepted?(NWWSSocket(connection: connection, queue: queue))
        }

        let boundPort = try await Self.awaitReady(listener, queue: queue)
        self.port = boundPort
        if advertise {
            self.startPermissionBrowser()
        }
        return boundPort
    }

    private func tearDownNW() {
        self.permissionBrowser?.cancel()
        self.permissionBrowser = nil
        self.listener?.cancel()
        self.listener = nil
        self.port = nil
    }

    /// Browse our own service type so macOS presents the Local Network
    /// permission prompt (see `permissionBrowser`). Results are ignored.
    private func startPermissionBrowser() {
        guard self.permissionBrowser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.canonicalServiceType, domain: nil), using: parameters)
        let log = self.log
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                log.debug("presence.localNetwork.browser.ready")

            case let .waiting(error):
                log.debug("presence.localNetwork.browser.waiting", ["error": String(reflecting: error)])

            case let .failed(error):
                log.error("presence.localNetwork.browser.failed", ["error": String(reflecting: error)])

            default:
                break
            }
        }
        browser.start(queue: self.queue)
        self.permissionBrowser = browser
    }

    private static func awaitReady(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            let claim: @Sendable () -> Bool = {
                resumed.withLock { was -> Bool in
                    let alreadyResumed = was
                    was = true
                    return !alreadyResumed
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }

                case let .failed(error):
                    if claim() {
                        continuation.resume(throwing: PresenceError.listenerFailed(String(reflecting: error)))
                    }

                default:
                    break
                }
            }
            listener.start(queue: queue)
            // A listener that neither reads nor fails inside the probe window
            // is treated as a failure so the fallback can engage.
            queue.asyncAfter(deadline: .now() + Self.startupProbeWindow) {
                if claim() {
                    continuation.resume(throwing: PresenceError.listenerFailed("startup probe timed out"))
                }
            }
        }
    }

    // MARK: BSD stack (fallback)

    private func startBSD(advertise: Bool) async throws -> UInt16 {
        let server = BSDWSServer()
        let accepted = self.onConnection
        server.onConnection = { transport in
            accepted?(transport)
        }
        let port = try server.start()
        self.bsdServer = server
        self.port = port

        if advertise, let name = self.pendingServiceName {
            let service = NetServicePresence()
            let log = self.log
            service.onPublishFailed = { failedName, code in
                log.error("presence.announce.failed", ["name": failedName, "code": String(code)])
            }
            service.publish(name: name, port: port, txt: self.pendingTXT)
            self.netService = service
        }
        return port
    }

    // MARK: Stop / re-advertise

    /// Withdraws the advertisement, closes the listener and the permission
    /// browser. Idempotent.
    public func stop() {
        self.permissionBrowser?.cancel()
        self.permissionBrowser = nil
        self.listener?.cancel()
        self.listener = nil
        self.bsdServer?.stop()
        self.bsdServer = nil
        self.netService?.stop()
        self.netService = nil
        self.advertising = false
        self.port = nil
    }

    /// Re-registers the Bonjour service after a wake, when the listener may
    /// have dropped it. No-op while not advertising.
    public func reAdvertise(serviceName: String, txt: NWTXTRecord) {
        guard self.advertising else { return }
        switch self.effectiveStack {
        case .networkFramework:
            guard let listener = self.listener else { return }
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.canonicalServiceType,
                txtRecord: txt
            )

        case .bsdSocket:
            guard let id = txt["id"] else { return }
            self.netService?.publish(
                name: serviceName,
                port: self.port ?? 0,
                txt: Self.txtPairs(
                    id: id,
                    name: txt["name"] ?? serviceName,
                    version: Int(txt["v"] ?? "") ?? 1
                )
            )

        case .automatic:
            return // resolved at start; never re-advertises
        }
    }
}
