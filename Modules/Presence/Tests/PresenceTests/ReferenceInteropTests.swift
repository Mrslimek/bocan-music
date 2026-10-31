import Foundation
import Observability
import Testing
@testable import Presence

// MARK: - Reference-peer interop

/// Dials a locally launched MusicShareMVP reference peer over a REAL
/// NWConnection WebSocket and runs the protocol against it: handshake,
/// state exchange, keepalive RTT, goodbye. The reference binary is found via
/// the `PRESENCE_MVP_BIN` environment variable; without it the test exits
/// early (it is not a repository dependency). The peer is launched and
/// terminated inside the test run only.
@Suite(.serialized)
struct ReferenceInteropTests {
    @Test
    func mvpDialsOurFallbackStack() async throws {
        // Vacuous pass without the reference binary; run with
        // PRESENCE_MVP_BIN=<path to MusicShareMVP> to exercise the interop.
        guard let mvpBin = ProcessInfo.processInfo.environment["PRESENCE_MVP_BIN"],
              FileManager.default.isExecutableFile(atPath: mvpBin) else {
            return
        }

        // The engine serves on the BSD fallback stack (forced, so the test
        // never depends on the NW listen path) and advertises via NetService.
        // Its id is GREATER than the MVP's, so the MVP's tie-break elects the
        // MVP as the dialer: it discovers us over mDNS, dials our BSD server,
        // and the whole session runs against the reference implementation.
        let peer = Self.launchReferencePeer(executable: mvpBin)
        defer {
            if peer.process.isRunning {
                peer.process.terminate()
            }
        }

        // The MVP prints `READY id=... port=...` once its WS server listens.
        let ready = try await Self.readReadyLine(file: peer.stdout.fileHandleForReading, within: 10)
        guard ready.port != nil else {
            Issue.record("reference peer did not report a port in: \(ready.line)")
            return
        }

        let store = LogStore(capacity: 4000)
        let engine = Harness.makeEngine(
            selfID: Self.engineID,
            name: "BocanInterop",
            config: Self.interopConfig,
            store: store
        )
        try await engine.start()
        try await Self.assertSession(peer: peer, engine: engine, store: store)
    }

    /// The full protocol session against the reference peer, dialer side the
    /// MVP: handshake, state both ways, keepalive RTT, and a clean goodbye.
    private static func assertSession(peer: ReferencePeer, engine: PresenceEngine, store: LogStore) async throws {
        // Handshake: the reference peer dialled in, hello/hello_ack done, and
        // it sent its own state snapshot.
        let connected = await waitUntil(within: 45) { [engine, peer] in
            await (engine.currentPeersForTesting()).contains {
                $0.id == peer.id && $0.connection == .connected
            }
        }
        #expect(connected)
        let sawState = await waitUntil(within: 6) { [engine, peer] in
            await (engine.currentPeersForTesting()).first { $0.id == peer.id }?.playback != nil
        }
        #expect(sawState)

        // Keepalive: pings answered, RTT recorded.
        let hasRTT = await waitUntil(within: 12) { [engine, peer] in
            await (engine.currentPeersForTesting()).first { $0.id == peer.id }?.rttMs != nil
        }
        #expect(hasRTT)

        // Clean goodbye, reference side: the MVP sends goodbye on its graceful
        // shutdown (contract sections 2 and 6), our engine records it, and the
        // reconnect ladder stays silent (goodbye = gone).
        peer.process.terminate()
        try await peer.process.waitUntilExit(within: 5)
        await Self.assertGoodbyeWithoutReconnect(engine: engine, store: store, peerID: peer.id)

        let mvpLog = Self.mvpLog(in: peer.logDir)
        #expect(mvpLog.contains("goodbye"))
        await engine.stop()
        if ProcessInfo.processInfo.environment["PRESENCE_DUMP_LOGS"] != nil {
            let lines = store.snapshot().map { entry in "ENGINE \(entry.message)" }
            try? lines.joined(separator: "\n").write(
                toFile: "/tmp/presence-interop.log", atomically: true, encoding: .utf8
            )
        }
    }

    /// Goodbye received from the (now terminated) reference peer, peer
    /// dropped to unreachable, zero reconnect_scheduled.
    private static func assertGoodbyeWithoutReconnect(engine: PresenceEngine, store: LogStore, peerID: String) async {
        let goodbyeLogged = await waitUntil(within: 6) { [store] in
            store.snapshot().contains { $0.message.contains("goodbye_recv") }
        }
        #expect(goodbyeLogged)
        let disconnected = await waitUntil(within: 4) { [engine] in
            await (engine.currentPeersForTesting()).first { $0.id == peerID }?.connection == .unreachable
        }
        #expect(disconnected)
        try? await Task.sleep(nanoseconds: 800_000_000)
        let reconnects = store.snapshot().filter { $0.message.contains("reconnect_scheduled") }
        #expect(reconnects.isEmpty)
    }

    /// The reference peer writes a JSONL session file (not `peer.log`).
    private static func mvpLog(in directory: String) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for file in files where file.hasSuffix(".jsonl") {
            if let contents = try? String(contentsOfFile: directory + "/" + file, encoding: .utf8) {
                return contents
            }
        }
        return ""
    }

    private static let interopConfig = PresenceConfig(
        pingInterval: 1.0,
        pongTimeout: 6.0,
        handshakeTimeout: 5.0,
        dialTimeout: 5.0,
        peerExpiry: 60,
        removalDebounce: 2.5,
        healthyPongAge: 15,
        tickInterval: 0.2,
        usesDiscovery: true,
        bindsListener: true,
        transportStack: .bsdSocket
    )

    /// Greater than the MVP's id, so the MVP's tie-break elects the MVP as
    /// the dialer and the session lands on our fallback server.
    private static let engineID = "ffffffff-0000-0000-0000-000000000100"

    private struct ReadyLine {
        let line: String
        let port: UInt16?
    }

    /// One launched MVP reference peer. The caller terminates `process`;
    /// the peer is alive only inside the test run.
    private struct ReferencePeer {
        let process: Process
        let stdout: Pipe
        let logDir: String
        let id: String
    }

    /// Launches one headless MVP peer.
    private static func launchReferencePeer(executable: String) -> ReferencePeer {
        let mvpID = "ffffffff-0000-0000-0000-0000000000ff"
        let logDir = NSTemporaryDirectory() + "presence-mvp-interop-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = [
            "--headless",
            "--name", "BocanRefPeer",
            "--id", mvpID,
            "--port", "0",
            "--log-dir", logDir,
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return ReferencePeer(process: process, stdout: stdout, logDir: logDir, id: mvpID)
    }

    private static func port(from line: Substring) -> UInt16? {
        let token = line.split(separator: " ").first { $0.hasPrefix("port=") }
        return token.flatMap { UInt16($0.dropFirst(5)) }
    }

    /// Reads MVP stdout until the READY line appears (bounded).
    private static func readReadyLine(file: FileHandle, within seconds: Double) async throws -> ReadyLine {
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = Data()
        while Date() < deadline {
            let chunk = file.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
                if let text = String(data: buffer, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.contains("READY") }) {
                    return ReadyLine(line: String(line), port: Self.port(from: line))
                }
            } else {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return ReadyLine(line: "", port: nil)
    }
}

extension Process {
    /// Bounded wait so a wedged reference peer cannot stall the suite.
    func waitUntilExit(within seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while self.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if self.isRunning {
            self.terminate()
        }
    }
}
