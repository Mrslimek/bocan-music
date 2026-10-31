import AppKit
import Persistence
import Playback
import Presence

/// Registers a `willTerminateNotification` observer that saves the current
/// playback position to `UserDefaults`, withdraws the Presence peer-protocol
/// engine (goodbye + unregister), and runs an opportunistic
/// `incremental_vacuum` before the process exits.
///
/// A `DispatchSemaphore` blocks termination briefly while the async save
/// completes; the timeout prevents a hang on slow devices.  Vacuum runs only
/// when the freelist exceeds the threshold defined inside `Database.vacuum()`
/// (ADR-003 audit #5 / #17).
func registerTerminationObserver(player: QueuePlayer, database: Database, presence: PresenceEngine) {
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: nil
    ) { _ in
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await player.savePositionForSuspend()
            // Best-effort vacuum; never block quit on a DB error.
            _ = try? await database.vacuum()
            // Presence's goodbye + unregister is bounded well under the budget
            // (0.15 s flush per connected peer plus teardown).
            await presence.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }
}
