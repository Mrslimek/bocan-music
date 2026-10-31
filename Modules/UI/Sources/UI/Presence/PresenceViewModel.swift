import Foundation
import Observability
import Presence
import SwiftUI

// MARK: - PresenceViewModel

/// State-store for Settings -> Presence. A protocol-free view model over the
/// `PresenceEngine` actor (the UI module may import Presence; the App wires
/// the engine in `buildGraph`).
///
/// The enable toggle owns the `presence.enabled` preference (default off) and
/// starts/stops the engine; the peer list follows the engine's directory
/// stream so the pane can show the live connection count.
@MainActor
@Observable
public final class PresenceViewModel {
    // MARK: Public state

    /// The `presence.enabled` preference as last loaded or set.
    public private(set) var enabled = false
    /// Whether peers may control local playback (`presence.controlEnabled`).
    public private(set) var controlEnabled = false
    /// Whether the engine is currently running.
    public private(set) var isRunning = false
    /// This Mac's persisted device id (full, shown as a tail in Settings).
    public private(set) var deviceID = ""
    /// This Mac's display name, resolved through the injected closure.
    public private(set) var deviceName = ""
    /// The bound listener port while running.
    public private(set) var port: UInt16?
    /// The live peer list from the engine's directory stream.
    public private(set) var peers: [PeerSnapshot] = []

    // MARK: Dependencies

    @ObservationIgnored private let engine: PresenceEngine
    @ObservationIgnored private let log = AppLogger.make(.ui)
    @ObservationIgnored private nonisolated(unsafe) var watchTask: Task<Void, Never>?

    /// - Parameter engine: the engine the App wired in `buildGraph`.
    public init(engine: PresenceEngine) {
        self.engine = engine
    }

    deinit {
        self.watchTask?.cancel()
    }

    // MARK: Loading

    /// Loads the toggle, self identity, and live peer list. Call from the view's
    /// `.task`.
    public func load() async {
        self.enabled = UserDefaults.standard.bool(forKey: "presence.enabled")
        // Default on: the registered default covers the first read.
        self.controlEnabled = UserDefaults.standard.object(forKey: "presence.controlEnabled") as? Bool ?? true
        let info = await self.engine.selfInfo()
        self.deviceID = info.id
        self.deviceName = info.name
        self.port = info.port
        self.isRunning = await self.engine.isRunning
        self.startWatching()
    }

    private func startWatching() {
        guard self.watchTask == nil else { return }
        let engine = self.engine
        self.watchTask = Task {
            let updates = await engine.peerUpdates()
            for await peers in updates {
                self.peers = peers
            }
        }
    }

    // MARK: Enable toggle

    /// Persists the toggle and starts (true) or stops (false) the engine.
    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "presence.enabled")
        if enabled {
            do {
                try await self.engine.start()
            } catch {
                self.log.error("presence.ui.start.failed", ["error": String(reflecting: error)])
            }
        } else {
            await self.engine.stop()
        }
        self.isRunning = await self.engine.isRunning
        let info = await self.engine.selfInfo()
        self.port = info.port
    }

    /// Persists the remote-control gate; the engine reads the same key live,
    /// so the next inbound command obeys it with no engine call.
    public func setControlEnabled(_ enabled: Bool) {
        self.controlEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "presence.controlEnabled")
    }

    /// Sends a remote-control command to one peer (fire-and-forget).
    public func sendCommand(to peer: PeerSnapshot, action: PresenceCommandAction) async {
        await self.engine.sendCommand(peerID: peer.id, action: action)
    }

    // MARK: Derived display state

    /// Peers currently CONNECTED with a live session.
    public var connectedCount: Int {
        self.peers.filter { $0.connection == .connected }.count
    }

    /// Peers discovered on the network but not connected.
    public var discoveredCount: Int {
        self.peers.filter { $0.connection != .connected && $0.discovery == .discovered }.count
    }

    /// The device id tail shown in Settings (enough to tell two Macs apart).
    public var deviceIDTail: String {
        String(self.deviceID.suffix(8))
    }
}
