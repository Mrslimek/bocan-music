import Foundation
import Observability
import Persistence
import Playback
import SyncServer

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
