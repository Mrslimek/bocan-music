import Foundation

/// Errors surfaced by the Presence subsystem. One enum per domain, carrying
/// context, per the repo standard.
public enum PresenceError: Error, Sendable, Equatable {
    /// The WebSocket listener failed to bind.
    case listenerFailed(String)
    /// A dial could not be completed (socket setup, resolution, or timeout).
    case dialFailed(String)
    /// The engine was asked for an operation that requires a running engine.
    case notRunning
    /// A manual connect target could not be parsed into a dialable endpoint.
    case invalidManualTarget(String)
}

extension PresenceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .listenerFailed(detail):
            "listener failed: \(detail)"

        case let .dialFailed(detail):
            "dial failed: \(detail)"

        case .notRunning:
            "presence engine is not running"

        case let .invalidManualTarget(detail):
            "invalid manual target: \(detail)"
        }
    }
}
