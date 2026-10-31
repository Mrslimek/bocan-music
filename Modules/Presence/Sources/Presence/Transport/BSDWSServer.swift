import Foundation

/// The BSD-socket TCP listener for the fallback stack: POSIX
/// socket/bind/listen on an ephemeral port, accepts via a `DispatchSourceRead`
/// on a private queue, and hands each accepted descriptor to the owner as a
/// server-role `BSDWSSocket` (which performs the WS upgrade handshake on its
/// own thread). This is the path that replaces `NWListener` where its listen
/// path is broken.
final class BSDWSServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.cloudcauldron.bocan.presence.bsdserver")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    /// Called on the server queue for every accepted connection.
    var onConnection: (@Sendable (WSTransport) -> Void)?

    /// Binds on an ephemeral port (or `preferred` when given) and starts
    /// accepting. Returns the actual bound port.
    func start(preferred: UInt16? = nil) throws -> UInt16 {
        let fd = try Self.openListener(preferred: preferred)
        let port = try Self.boundPort(fd: fd)

        self.lock.withLock {
            self.listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.acceptOne(listenFD: fd)
            }
            source.setCancelHandler {
                BSDSocketIO.close(fd)
            }
            source.resume()
            self.readSource = source
        }
        return port
    }

    private static func openListener(preferred: UInt16?) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PresenceError.listenerFailed("socket errno=\(errno)")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferred.map { $0.bigEndian } ?? 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = errno
            BSDSocketIO.close(fd)
            throw PresenceError.listenerFailed("bind errno=\(error)")
        }
        guard listen(fd, 8) == 0 else {
            let error = errno
            BSDSocketIO.close(fd)
            throw PresenceError.listenerFailed("listen errno=\(error)")
        }
        return fd
    }

    private static func boundPort(fd: Int32) throws -> UInt16 {
        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else {
            let error = errno
            BSDSocketIO.close(fd)
            throw PresenceError.listenerFailed("getsockname errno=\(error)")
        }
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    /// Closes the listener; accepted sockets keep running independently.
    func stop() {
        self.lock.withLock {
            self.readSource?.cancel()
            self.readSource = nil
            self.listenFD = -1
        }
    }

    private func acceptOne(listenFD: Int32) {
        var clientAddr = sockaddr()
        var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = accept(listenFD, &clientAddr, &clientLength)
        guard clientFD >= 0 else { return }
        self.onConnection?(BSDWSSocket.server(acceptedFD: clientFD))
    }
}
