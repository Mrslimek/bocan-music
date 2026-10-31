import Foundation
import Network
import Observability

/// One resolved mDNS advertisement (contract section 2): the TXT-derived device
/// id and display name, plus the service endpoint a dial can use directly
/// (Network.framework resolves the SRV itself).
public struct PresenceAnnouncement: Sendable, Equatable {
    public let peerID: String
    public let name: String
    public let endpoint: NWEndpoint
    /// Resolved host/port, present when the discovery stack resolved the
    /// service itself (NetService); the BSD dial path dials this directly.
    public let host: String?
    public let port: UInt16?

    public init(peerID: String, name: String, endpoint: NWEndpoint, host: String? = nil, port: UInt16? = nil) {
        self.peerID = peerID
        self.name = name
        self.endpoint = endpoint
        self.host = host
        self.port = port
    }
}

/// mDNS browse events forwarded to the engine. The engine owns every churn
/// defense (removal debounce, healthy-socket guard, expiry); this actor only
/// reports what DNS-SD said, parsed.
public enum PresenceDiscoveryEvent: Sendable {
    case found(PresenceAnnouncement)
    case removed(peerID: String)
    case failed(String)
}

/// Browses `_musicshare._tcp` with `NWBrowser` and reports parsed peers.
///
/// Browse results carry the TXT record (`Result.Metadata.bonjour`), so the
/// device id needed for the dial tie-break (contract section 3) is available
/// without a separate resolve step. Results whose TXT lacks a usable id or
/// advertise a foreign protocol version are logged and ignored.
public actor PresenceBrowser {
    private let serviceType: String
    private let selfID: String
    private let protocolVersion: Int
    private let onEvent: @Sendable (PresenceDiscoveryEvent) -> Void
    private let log = AppLogger.make(.presence)

    private var browser: NWBrowser?
    private var queue: DispatchQueue?
    /// The ids currently present in the browse result set, for restart and
    /// debounce bookkeeping.
    private var knownPeerIDs: Set<String> = []

    /// - Parameters:
    ///   - serviceType: the browsed DNS-SD type (`_musicshare._tcp`).
    ///   - selfID: this device's id; our own announcements are skipped.
    ///   - protocolVersion: the TXT `v` a peer must advertise to count.
    ///   - onEvent: parsed found/removed/failed events, invoked off-actor.
    public init(serviceType: String, selfID: String, protocolVersion: Int, onEvent: @escaping @Sendable (PresenceDiscoveryEvent) -> Void) {
        self.serviceType = serviceType
        self.selfID = selfID
        self.protocolVersion = protocolVersion
        self.onEvent = onEvent
    }

    /// Starts browsing on the given queue. Idempotent while running.
    public func start(queue: DispatchQueue) {
        guard self.browser == nil else { return }
        self.queue = queue
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.resultsChanged(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(error):
                let detail = String(reflecting: error)
                Task { await self.emit(.failed(detail)) }

            case let .waiting(error):
                self.log.debug("presence.browse.waiting", ["error": String(reflecting: error)])

            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        self.log.debug("presence.discovery.start", ["serviceType": self.serviceType])
    }

    /// Cancels the browser and forgets the current result set. Idempotent.
    public func stop() {
        self.browser?.cancel()
        self.browser = nil
        self.queue = nil
        self.knownPeerIDs.removeAll()
    }

    /// Detaches the current browser and starts a fresh one. A fresh browse
    /// re-delivers every live service, which refreshes each peer's
    /// re-announcement timestamp (contract section 2's 60 s expiry is keyed on
    /// announcements, so without this long-lived silent services would falsely
    /// expire). The old browser's handlers are cleared before cancel so its
    /// teardown cannot deliver a spurious removal (MVP defect 6 defense).
    public func restart() {
        guard self.queue != nil else { return }
        if let old = self.browser {
            old.browseResultsChangedHandler = nil
            old.stateUpdateHandler = nil
            old.cancel()
        }
        self.browser = nil
        self.knownPeerIDs.removeAll()
        if let queue = self.queue {
            self.start(queue: queue)
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var found: [PresenceAnnouncement] = []
        var presentIDs: Set<String> = []
        for result in results {
            guard let announcement = Self.parse(result, selfID: self.selfID, protocolVersion: self.protocolVersion) else {
                continue
            }
            presentIDs.insert(announcement.peerID)
            if !self.knownPeerIDs.contains(announcement.peerID) {
                found.append(announcement)
            }
        }
        let removed = self.knownPeerIDs.subtracting(presentIDs)
        self.knownPeerIDs = presentIDs

        for announcement in found {
            self.log.debug("presence.browse.found", [
                "peer": announcement.peerID,
                "name": announcement.name,
            ])
            self.emit(.found(announcement))
        }
        for peerID in removed {
            self.log.debug("presence.browse.removed", ["peer": peerID])
            self.emit(.removed(peerID: peerID))
        }
    }

    private func emit(_ event: PresenceDiscoveryEvent) {
        self.onEvent(event)
    }

    private static func parse(_ result: NWBrowser.Result, selfID: String, protocolVersion: Int) -> PresenceAnnouncement? {
        guard case let .bonjour(txt) = result.metadata,
              let id = txt["id"], !id.isEmpty else {
            return nil
        }
        guard id != selfID else { return nil }
        guard txt["v"] == String(protocolVersion) else {
            return nil
        }
        return PresenceAnnouncement(peerID: id, name: txt["name"] ?? id, endpoint: result.endpoint)
    }
}
