import Foundation
import Network
import Observability

/// mDNS advertise + browse over Foundation `NetService`/`NetServiceBrowser`,
/// the MVP-proven stack: it works where the `NWListener`/`NWBrowser` listen
/// path is broken, including unbundled processes. Both roles run on a private
/// thread's run loop (NetService callbacks arrive where the service is
/// scheduled); events are forwarded with the same shapes as
/// `PresenceBrowser`, so the engine treats the two discovery stacks alike.
///
/// A fresh browse re-delivers every live service (`didFind`), which refreshes
/// each peer's announcement clock; `restartBrowsing()` detaches the old
/// browser before starting the new one so teardown cannot deliver a spurious
/// removal (the MVP's defect 6 defense).
final class NetServicePresence: NSObject, @unchecked Sendable {
    static let serviceType = "_musicshare._tcp."
    static let serviceDomain = "local."

    private let lock = NSLock()
    private var runLoop: RunLoop?
    private var threadStarted = false
    private var stopRequested = false

    private var publisher: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var nameToID: [String: String] = [:]

    /// Browse events (found/removed/failed), invoked off the service thread.
    var onEvent: (@Sendable (PresenceDiscoveryEvent) -> Void)?
    /// Publish failures (domain, dns_sd code) for announce logging.
    var onPublishFailed: (@Sendable (String, Int) -> Void)?

    private let log = AppLogger.make(.presence)

    // MARK: Lifecycle

    private func ensureThread() {
        self.lock.lock()
        if self.threadStarted {
            self.lock.unlock()
            return
        }
        self.threadStarted = true
        self.lock.unlock()

        let thread = Thread { [weak self] in
            Thread.current.name = "io.cloudcauldron.bocan.presence.netservice"
            let runLoop = RunLoop.current
            runLoop.add(Port(), forMode: .default)
            self?.lock.withLock {
                self?.runLoop = runLoop
            }
            while !(self?.lock.withLock { self?.stopRequested ?? true } ?? true) {
                runLoop.run(mode: .default, before: Date().addingTimeInterval(1))
            }
        }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private func perform(_ block: @escaping @Sendable () -> Void) {
        self.ensureThread()
        // Wait briefly for the service thread's run loop to come up.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let runLoop = self.lock.withLock({ self.runLoop }) {
                runLoop.perform(block)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        self.log.warning("presence.netservice.thread.unavailable")
    }

    // MARK: Publish (advertise)

    /// Publishes (or re-publishes) the service with the contract TXT record.
    func publish(name: String, port: UInt16, txt: [(String, String)]) {
        self.perform { [weak self] in
            guard let self else { return }
            let old = self.lock.withLock { self.publisher }
            old?.stop()
            let service = NetService(
                domain: Self.serviceDomain,
                type: Self.serviceType,
                name: name,
                port: Int32(port)
            )
            service.setTXTRecord(Self.txtRecord(txt))
            service.delegate = self
            service.schedule(in: .current, forMode: .default)
            self.lock.withLock { self.publisher = service }
            service.publish()
        }
    }

    func stopPublishing() {
        self.perform { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.publisher }?.stop()
            self.lock.withLock { self.publisher = nil }
        }
    }

    // MARK: Browse (discover)

    func startBrowsing() {
        self.perform { [weak self] in
            self?.startBrowserOnCurrentRunLoop()
        }
    }

    /// Detaches the current browser and starts a fresh one; the new browse
    /// re-delivers every live service, refreshing announcement clocks.
    func restartBrowsing() {
        self.perform { [weak self] in
            self?.startBrowserOnCurrentRunLoop()
        }
    }

    private func startBrowserOnCurrentRunLoop() {
        let old = self.lock.withLock { self.browser }
        // Detach before stop: a stopping browser can deliver teardown events
        // that would falsely mark live peers removed.
        old?.delegate = nil
        old?.stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        self.lock.withLock {
            self.browser = browser
            self.nameToID.removeAll()
        }
        browser.searchForServices(ofType: Self.serviceType, inDomain: Self.serviceDomain)
    }

    func stopBrowsing() {
        self.perform { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.browser }?.stop()
            self.lock.withLock {
                self.browser = nil
                self.resolving.forEach { $0.stop() }
                self.resolving.removeAll()
                self.nameToID.removeAll()
            }
        }
    }

    /// Ends the service thread. Idempotent.
    func stop() {
        self.stopPublishing()
        self.stopBrowsing()
        self.lock.withLock {
            self.stopRequested = true
        }
        if let runLoop = self.lock.withLock({ self.runLoop }) {
            CFRunLoopStop(runLoop.getCFRunLoop())
        }
    }

    // MARK: TXT wire codec (DNS-SD: length-prefixed "key=value" pairs)

    static func txtRecord(_ items: [(String, String)]) -> Data {
        var out = Data()
        for (key, value) in items {
            let pair = Array("\(key)=\(value)".utf8)
            guard !pair.isEmpty, pair.count <= 255 else { continue }
            out.append(UInt8(pair.count))
            out.append(contentsOf: pair)
        }
        return out
    }

    static func decodeTXT(_ data: Data?) -> [String: String] {
        guard let data else { return [:] }
        var out: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard length > 0, index < data.endIndex else { break }
            let end = min(data.index(index, offsetBy: length), data.endIndex)
            if let pair = String(data: data[index..<end], encoding: .utf8),
               let equals = pair.firstIndex(of: "=") {
                out[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            index = end
        }
        return out
    }
}

// MARK: - NetServiceDelegate (publish)

extension NetServicePresence: NetServiceDelegate, NetServiceBrowserDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        self.log.debug("presence.announce.published", [
            "name": sender.name,
            "port": String(sender.port),
        ])
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = Self.errorCode(from: errorDict)
        self.log.error("presence.announce.failed", ["name": sender.name, "code": String(code)])
        self.onPublishFailed?(sender.name, code)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        self.lock.withLock {
            self.resolving.removeAll { $0 == sender }
        }
        self.log.debug("presence.resolve.failed", [
            "name": sender.name,
            "code": String(Self.errorCode(from: errorDict)),
        ])
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        self.lock.withLock {
            self.resolving.removeAll { $0 == sender }
        }
        let txt = Self.decodeTXT(sender.txtRecordData())
        guard let id = txt["id"], !id.isEmpty else {
            self.log.debug("presence.resolve.invalid", ["name": sender.name, "reason": "TXT missing id"])
            return
        }
        guard txt["v"] == "1" else {
            self.log.debug("presence.resolve.invalid", ["name": sender.name, "reason": "unsupported v"])
            return
        }
        guard let host = sender.hostName, sender.port > 0 else {
            self.log.debug("presence.resolve.invalid", ["name": sender.name, "reason": "no host/port"])
            return
        }
        self.lock.withLock {
            self.nameToID[sender.name] = id
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else {
            self.log.debug("presence.resolve.invalid", ["name": sender.name, "reason": "bad port"])
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        let announcement = PresenceAnnouncement(
            peerID: id,
            name: txt["name"] ?? id,
            endpoint: endpoint,
            host: host,
            port: port.rawValue
        )
        self.onEvent?(.found(announcement))
    }

    // MARK: NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        self.lock.withLock { self.resolving.append(service) }
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = self.lock.withLock { self.nameToID.removeValue(forKey: service.name) }
        guard let id else { return }
        self.onEvent?(.removed(peerID: id))
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        self.log.debug("presence.browse.netservice.start")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        self.log.error("presence.browse.netservice.failed", ["code": String(Self.errorCode(from: errorDict))])
        self.onEvent?(.failed("browse failed code=\(Self.errorCode(from: errorDict))"))
    }

    private static func errorCode(from dict: [String: NSNumber]) -> Int {
        // The dns_sd code sits under the PLURAL key (the MVP's defect 4 fix).
        dict["NSNetServicesErrorCode"]?.intValue
            ?? dict["NSNetServiceErrorCode"]?.intValue
            ?? 0
    }
}
