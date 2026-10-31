import Foundation

/// WebSocket transport over a BSD socket for the fallback stack. Two roles:
/// the SERVER socket wraps an accepted descriptor and performs the RFC 6455
/// upgrade handshake (unmasked sends, client frames arrive masked), and the
/// CLIENT socket dials, sends the upgrade request (masked sends) and validates
/// the 101. Both run their IO on a dedicated thread so no cooperative-pool
/// thread ever blocks, and both speak the same `WSTransport` seam as
/// `NWWSSocket`, so the connection actor cannot tell the stacks apart.
final class BSDWSSocket: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let masking: Bool
    /// The dialed host and port, for the client handshake's Host header.
    private let host: String
    private let port: UInt16
    private var sinkStorage: (@Sendable (WSEvent) -> Void)?
    private static let noSink: @Sendable (WSEvent) -> Void = { _ in }
    private var assembler = WSMessageAssembler()
    /// Set by close()/cancel() so the reader thread does not also emit a death.
    private var localClose = false

    var onEvent: @Sendable (WSEvent) -> Void {
        get { self.lock.withLock { self.sinkStorage } ?? Self.noSink }
        set { self.lock.withLock { self.sinkStorage = newValue } }
    }

    private func sink() -> (@Sendable (WSEvent) -> Void)? {
        self.lock.withLock { self.sinkStorage }
    }

    private init(fd: Int32, masking: Bool, host: String, port: UInt16 = 0) {
        self.fd = fd
        self.masking = masking
        self.host = host
        self.port = port
    }

    /// Server role: the descriptor is an accepted connection whose HTTP
    /// upgrade request has not been answered yet.
    static func server(acceptedFD: Int32) -> BSDWSSocket {
        BSDWSSocket(fd: acceptedFD, masking: false, host: "")
    }

    /// Client role: dials `host:port` and performs the upgrade request.
    static func client(host: String, port: UInt16) -> BSDWSSocket? {
        guard let fd = BSDSocketIO.connect(host: host, port: port) else { return nil }
        return BSDWSSocket(fd: fd, masking: true, host: host, port: port)
    }

    func start() {
        let thread = Thread { [weak self] in
            Thread.current.name = "io.cloudcauldron.bocan.presence.bsdws"
            self?.run()
        }
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private func run() {
        guard let fd = self.lock.withLock({ self.fd >= 0 ? self.fd : nil }) else { return }
        let handshake: Bool
        if self.masking {
            handshake = self.performClientHandshake(fd: fd)
        } else {
            handshake = self.performServerHandshake(fd: fd)
        }
        guard handshake else {
            self.emitIfRemote(.failed("handshake failed"))
            self.closeFD()
            return
        }
        self.emit(.open)
        self.readLoop(fd: fd)
    }

    // MARK: Handshakes

    private func performServerHandshake(fd: Int32) -> Bool {
        guard let raw = BSDSocketIO.readUntil(headerEnd: Data("\r\n\r\n".utf8), on: fd) else {
            return false
        }
        let key = Self.webSocketKey(from: raw)
        guard let key, let accept = WSFrameCodec.acceptHeader(for: key) else {
            let bad = "HTTP/1.1 400 Bad Request\r\n\r\n"
            _ = BSDSocketIO.send(fd, Data(bad.utf8))
            return false
        }
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        return BSDSocketIO.send(fd, Data(response.utf8))
    }

    private func performClientHandshake(fd: Int32) -> Bool {
        let keyData = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = Data(keyData).base64EncodedString()
        let request = "GET / HTTP/1.1\r\n" +
            "Host: \(self.host):\(self.port)\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(key)\r\n" +
            "Sec-WebSocket-Version: 13\r\n\r\n"
        guard BSDSocketIO.send(fd, Data(request.utf8)) else { return false }
        guard let raw = BSDSocketIO.readUntil(headerEnd: Data("\r\n\r\n".utf8), on: fd) else {
            return false
        }
        let head = String(bytes: raw, encoding: .utf8) ?? ""
        guard head.contains(" 101 "), let sentAccept = WSFrameCodec.acceptHeader(for: key) else {
            return false
        }
        return head.contains(sentAccept)
    }

    private static func webSocketKey(from raw: Data) -> String? {
        guard let head = String(bytes: raw, encoding: .utf8) else { return nil }
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-key" {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: Read loop

    private func readLoop(fd: Int32) {
        var buffer = Data()
        while true {
            guard let chunk = BSDSocketIO.recv(fd) else {
                // Clean EOF or error: a remote close we did not answer, or the
                // local teardown unblocked the read.
                self.emitIfRemote(.remoteClose(code: 1006, reason: "connection closed"))
                break
            }
            buffer.append(chunk)
            var drained = false
            while !drained {
                switch WSFrameCodec.decode(&buffer) {
                case .needMore:
                    drained = true

                case .oversize:
                    self.emitIfRemote(.failed("frame exceeds max size"))
                    self.closeFD()
                    return

                case let .frame(frame):
                    switch self.assembler.ingest(frame) {
                    case .needMore:
                        continue

                    case let .event(event):
                        switch event {
                        case let .text(text):
                            self.emitIfRemote(.text(text))

                        case let .close(code, reason):
                            // Answer the close handshake, then end the session.
                            self.sendFrame(WSFrame(fin: true, opcode: 0x8, payload: Data()))
                            self.emitIfRemote(.remoteClose(code: code, reason: reason))
                            self.closeFD()
                            return

                        case let .ping(payload):
                            self.sendFrame(WSFrame(fin: true, opcode: 0xA, payload: payload))

                        case .pong:
                            break
                        }

                    case let .invalid(reason):
                        self.emitIfRemote(.failed("protocol error: \(reason)"))
                        self.closeFD()
                        return
                    }
                }
            }
        }
    }

    // MARK: WSTransport

    func send(_ text: String) {
        self.sendFrame(WSFrame(fin: true, opcode: 0x1, payload: Data(text.utf8)))
    }

    private func sendFrame(_ frame: WSFrame) {
        let fd = self.lock.withLock { self.fd }
        guard fd >= 0 else { return }
        _ = BSDSocketIO.send(fd, WSFrameCodec.encode(frame: frame, mask: self.masking))
    }

    func close(code: UInt16, reason: String) {
        self.lock.withLock { self.localClose = true }
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(contentsOf: Array(reason.utf8.prefix(120)))
        self.sendFrame(WSFrame(fin: true, opcode: 0x8, payload: payload))
        self.closeFD()
    }

    func cancel() {
        self.lock.withLock { self.localClose = true }
        self.closeFD()
    }

    // MARK: Plumbing

    private func emit(_ event: WSEvent) {
        self.sink()?(event)
    }

    /// A `.failed`/`.remoteClose` from the reader thread only counts as a
    /// death when the close was not local: the local path emits its own
    /// terminal event first.
    private func emitIfRemote(_ event: WSEvent) {
        let remote = !self.lock.withLock { self.localClose }
        if remote {
            self.emit(event)
        }
    }

    private func closeFD() {
        let fd = self.lock.withLock { () -> Int32 in
            let current = self.fd
            self.fd = -1
            return current
        }
        BSDSocketIO.close(fd)
    }
}
