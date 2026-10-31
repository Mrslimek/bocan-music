import Foundation
import Network
import os

// MARK: - Transport seam

/// Events a WebSocket transport surfaces to its owning connection actor.
public enum WSEvent: Sendable, Equatable {
    /// The socket is open (WS upgrade complete).
    case open
    /// One JSON text frame arrived.
    case text(String)
    /// The peer sent a close frame (code + reason; reason may be empty).
    case remoteClose(code: UInt16, reason: String)
    /// The transport failed or was cancelled before a clean close.
    case failed(String)
}

/// The per-connection transport seam. Production is `NWWSSocket`; tests drive
/// a mock to exercise handshake, keepalive and teardown latches deterministically.
public protocol WSTransport: AnyObject, Sendable {
    /// The event sink. Set by the owning connection actor right after
    /// construction, so the transport can outlive no owner (its callback holds
    /// the actor weakly).
    var onEvent: @Sendable (WSEvent) -> Void { get set }
    /// Begins connecting / reading. Events arrive on the injected callback.
    func start()
    /// Sends one JSON text frame.
    func send(_ text: String)
    /// Sends a WS close frame with the given code (custom 4xxx codes included),
    /// then cancels the underlying connection.
    func close(code: UInt16, reason: String)
    /// Cancels without a close frame (dial timeout into a dead peer).
    func cancel()
}

// MARK: - NWConnection implementation

/// WebSocket-over-TCP transport built on `NWConnection` with the
/// `NWProtocolWebSocket` application protocol. Used for both dials (client) and
/// accepted sockets (server side): the Network framework performs the WS
/// handshake for both, and `NWProtocolWebSocket.CloseCode.protocolCode` can send
/// the contract's custom close codes (4002/4003), which `URLSessionWebSocketTask`
/// cannot. All state is confined to the injected queue.
final class NWWSSocket: WSTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let callbackBox = OSAllocatedUnfairLock<CallbackBox>(initialState: CallbackBox())
    /// Guards the receive loop against re-entry while a receive is in flight.
    private var receiving = false
    /// Set when the close/cancel was local, so the resulting `.cancelled` state
    /// does not also surface as a transport death (the local path emits its own
    /// terminal event; one decision, one death event).
    private var localCloseInitiated = false

    private struct CallbackBox: Sendable {
        var handler: (@Sendable (WSEvent) -> Void)?
    }

    private static let noopHandler: @Sendable (WSEvent) -> Void = { _ in }

    var onEvent: @Sendable (WSEvent) -> Void {
        get { self.callbackBox.withLock { $0.handler } ?? Self.noopHandler }
        set { self.callbackBox.withLock { $0.handler = newValue } }
    }

    init(endpoint: NWEndpoint, parameters: NWParameters, queue: DispatchQueue) {
        self.connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
    }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    private func emit(_ event: WSEvent) {
        self.callbackBox.withLock { $0.handler }?(event)
    }

    func start() {
        self.connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.emit(.open)
                self.receiveNext()

            case let .failed(error):
                self.emit(.failed(String(reflecting: error)))

            case .cancelled:
                // A cancel we did not initiate surfaces as a bare death; local
                // close() paths emit their own terminal event first.
                if !self.localCloseInitiated {
                    self.emit(.failed("cancelled"))
                }

            default:
                break
            }
        }
        self.connection.start(queue: self.queue)
    }

    func send(_ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        self.connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.emit(.failed(String(reflecting: error)))
                }
            }
        )
    }

    func close(code: UInt16, reason: String) {
        self.localCloseInitiated = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = Self.closeCode(for: code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        self.connection.send(
            content: Data(reason.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            }
        )
    }

    func cancel() {
        self.localCloseInitiated = true
        self.connection.cancel()
    }

    /// Maps a contract close code onto the Network framework enum: 4000-4999
    /// are application codes (4002 handshake timeout, 4003 superseded), the
    /// standard IANA range is `Defined`, everything else private.
    private static func closeCode(for code: UInt16) -> NWProtocolWebSocket.CloseCode {
        if let defined = NWProtocolWebSocket.CloseCode.Defined(rawValue: code) {
            return .protocolCode(defined)
        }
        if (4000 ... 4999).contains(code) {
            return .applicationCode(code)
        }
        return .privateCode(code)
    }

    private static func rawCloseCode(_ closeCode: NWProtocolWebSocket.CloseCode) -> UInt16 {
        switch closeCode {
        case let .protocolCode(defined):
            defined.rawValue

        case let .applicationCode(code):
            code

        case let .privateCode(code):
            code

        @unknown default:
            0
        }
    }

    private func receiveNext() {
        guard !self.receiving else { return }
        self.receiving = true
        self.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            self.receiving = false
            if let context {
                self.handleContext(context, data: data)
            }
            if let error {
                self.emit(.failed(String(reflecting: error)))
                return
            }
            self.receiveNext()
        }
    }

    private func handleContext(_ context: NWConnection.ContentContext, data: Data?) {
        guard let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else {
            if let data, let text = String(data: data, encoding: .utf8) {
                self.emit(.text(text))
            }
            return
        }
        switch metadata.opcode {
        case .text:
            if let data, let text = String(data: data, encoding: .utf8) {
                self.emit(.text(text))
            }

        case .close:
            let raw = Self.rawCloseCode(metadata.closeCode)
            let reason = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.emit(.remoteClose(code: raw, reason: reason))

        default:
            // Protocol-level pings are auto-replied by the stack; other frames
            // are ignored per the receiver rules.
            break
        }
    }
}

// MARK: - WS parameters

enum WSParameters {
    /// Plain-WebSocket TCP parameters (no TLS: the contract's v1 peer network is
    /// a trusted LAN, matching the MVP reference implementation).
    static func make() -> NWParameters {
        let options = NWProtocolWebSocket.Options()
        // The contract's ping/pong is the application-level JSON pair; protocol
        // pings are orthogonal and auto-replying keeps middlemen happy.
        options.autoReplyPing = true
        let parameters = NWParameters()
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
}
