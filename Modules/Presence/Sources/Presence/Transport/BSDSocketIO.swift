import Foundation

/// Raw POSIX TCP helpers shared by the BSD WebSocket transports. Every call is
/// synchronous; the transports run them on their own dedicated threads so the
/// cooperative pool is never blocked.
enum BSDSocketIO {
    /// Creates a connected TCP socket to `host:port` (IPv4). Returns nil on
    /// any failure (resolution, connect, errno).
    static func connect(host: String, port: UInt16) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let result = getaddrinfo(host, String(port), &hints, &info)
        guard result == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }

        for candidate in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            if Darwin.connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                return fd
            }
            close(fd)
        }
        return nil
    }

    static func send(_ fd: Int32, _ data: Data) -> Bool {
        guard let pointer = data.withUnsafeBytes({ $0.bindMemory(to: UInt8.self).baseAddress }) else {
            return true // nothing to send
        }
        var sent = 0
        while sent < data.count {
            let n = Darwin.send(fd, pointer.advanced(by: sent), data.count - sent, 0)
            if n <= 0 {
                return false
            }
            sent += n
        }
        return true
    }

    /// One blocking recv; returns nil on clean EOF, empty on error.
    static func recv(_ fd: Int32, max: Int = 65_536) -> Data? {
        var buffer = [UInt8](repeating: 0, count: max)
        let n = Darwin.recv(fd, &buffer, max, 0)
        if n > 0 {
            return Data(buffer.prefix(n))
        }
        return nil
    }

    /// Blocking read-until delimiter for the HTTP handshake phase.
    static func readUntil(headerEnd marker: Data, on fd: Int32, limit: Int = 16_384) -> Data? {
        var buffer = Data()
        while true {
            guard let chunk = Self.recv(fd), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if buffer.count > limit {
                return nil
            }
            if buffer.range(of: marker) != nil {
                return buffer
            }
        }
    }

    /// Shuts the descriptor down (unblocking a thread parked in recv) and
    /// closes it exactly once per call site.
    static func close(_ fd: Int32) {
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}
