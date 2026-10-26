import AppKit
import Foundation
import Observability
import Persistence
import Playback
import SwiftUI
import SyncServer
import UI

/// Everything that has to happen before the process exits, collected in one
/// place so `AppDelegate.applicationShouldTerminate` can await it while the
/// main thread stays free.
///
/// Nothing here may block the main thread. `savePositionForSuspend()` writes
/// `UserDefaults`, whose change notification SwiftUI delivers through an
/// operation that waits for the main queue; blocking main while that write is
/// in flight deadlocks until the wait times out. That was the old
/// `DispatchSemaphore` handler's bug: every quit paused for two seconds.
struct AppShutdown: Sendable {
    let player: QueuePlayer
    let database: Database
    let syncServer: SyncServer

    private static let log = AppLogger.make(.app)

    /// Saves the resume point, withdraws Phone Sync, and runs the opportunistic
    /// database vacuum. Safe to call repeatedly; every step is idempotent.
    func perform() async {
        let start = Date()
        Self.log.debug("app.quit.shutdown_start")

        await self.player.savePositionForSuspend()
        await self.syncServer.stop()

        do {
            _ = try await self.database.vacuum()
        } catch {
            Self.log.warning("app.quit.vacuum_failed", ["error": String(reflecting: error)])
        }

        Self.log.debug("app.quit.shutdown_end", ["ms": -start.timeIntervalSinceNow * 1000])
    }

    /// Runs `perform()` and returns `false` when it has not finished within
    /// `timeout`.
    ///
    /// The work is abandoned rather than cancelled: the process is about to
    /// exit, and a task stuck in a database call must not hold termination
    /// hostage. The main thread is never blocked, so the timeout is a real
    /// bound rather than a beachball.
    func performWithTimeout(_ timeout: Duration) async -> Bool {
        let (results, continuation) = AsyncStream<Bool>.makeStream()

        let work = Task {
            await self.perform()
            continuation.yield(true)
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(false)
            continuation.finish()
        }

        defer {
            timer.cancel()
            continuation.finish()
        }

        for await finished in results {
            work.cancel()
            return finished
        }
        return false
    }
}

/// A small, non-activating panel that tells the listener the app is finishing
/// its quit-time work.
///
/// `AppDelegate` shows it only when that work outlives a short grace period, so
/// a normal quit (milliseconds) never flashes a spinner.
@MainActor
final class QuittingPanelController {
    private static let size = NSSize(width: 220, height: 100)

    private var panel: NSPanel?

    func show() {
        guard self.panel == nil else { return }

        let content = NSHostingView(rootView: QuittingView())
        content.frame = NSRect(origin: .zero, size: Self.size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.center()
        panel.orderFrontRegardless()

        self.panel = panel
    }

    func close() {
        self.panel?.orderOut(nil)
        self.panel?.contentView = nil
        self.panel = nil
    }
}
