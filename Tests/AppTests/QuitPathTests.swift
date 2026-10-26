import Foundation
import Testing

// MARK: - QuitPathTests

/// Guards the quit path against blocking the main thread.
///
/// `applicationShouldTerminate` runs host-less in the AppTests bundle, so the
/// delegate cannot be exercised here. The bug this pins was structural: a
/// synchronous `willTerminate` observer waited on a semaphore while a detached
/// task wrote `UserDefaults`, and SwiftUI's defaults observer waited on the
/// blocked main queue. Every quit took the full two-second timeout. These
/// source checks keep the blocking shape from coming back.
@Suite("Quit path")
struct QuitPathTests {
    private func appSource(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // AppTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Shutdown work never blocks the main thread")
    func noBlockingWait() throws {
        let lifecycle = try self.appSource("App/Lifecycle.swift")
        let app = try self.appSource("App/BocanApp.swift")
        #expect(!lifecycle.contains("DispatchSemaphore("), "quit work must not wait on a semaphore")
        #expect(!app.contains("semaphore.wait"), "BocanApp must not block termination")
        #expect(!app.contains("willTerminateNotification"), "quit work belongs in applicationShouldTerminate")
    }

    @Test("Shutdown is awaited through terminateLater before the reply")
    func terminateLaterAndReply() throws {
        let app = try self.appSource("App/BocanApp.swift")
        #expect(app.contains("return .terminateLater"))
        #expect(app.contains("NSApp.reply(toApplicationShouldTerminate: true)"))
        #expect(app.contains("shutdown.performWithTimeout("))
        #expect(app.contains("shutdownTimeout"))
    }

    @Test("Playback position, Phone Sync and vacuum still run on quit")
    func shutdownKeepsExistingWork() throws {
        let lifecycle = try self.appSource("App/Lifecycle.swift")
        #expect(lifecycle.contains("savePositionForSuspend()"))
        #expect(lifecycle.contains("database.vacuum()"))
        #expect(lifecycle.contains("syncServer.stop()"))
    }
}
