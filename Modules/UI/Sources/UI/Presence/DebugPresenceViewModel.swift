import Foundation
import Observability

// MARK: - DebugPresenceLine

/// One formatted line in the Debug Presence window: the log entry's timestamp
/// plus its already-formatted k=v message (direction arrows included).
public struct DebugPresenceLine: Identifiable, Equatable {
    public let id: UInt64
    public let text: String

    public init(id: UInt64, timestamp: Date, message: String) {
        self.id = id
        self.text = Self.formatter.string(from: timestamp) + "  " + message
    }

    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - DebugPresenceViewModel

/// Live, human-readable log of inter-device Presence traffic for the debug
/// window: a filtered, formatted view over `LogStore.backfillAndSubscribe()`,
/// kept to the `.presence` category. The engine logs every protocol event
/// through `AppLogger.make(.presence)` with direction arrows and key fields,
/// so this view formats, it does not parse wire JSON.
@MainActor
@Observable
public final class DebugPresenceViewModel {
    /// Rendered lines, oldest first, capped at the buffer size.
    public private(set) var lines: [DebugPresenceLine] = []

    /// `true` while the view follows the newest line.
    public var isTailing = true

    @ObservationIgnored private let store: LogStore
    @ObservationIgnored private var entries: [LogEntry] = []
    @ObservationIgnored private var pending: [LogEntry] = []
    @ObservationIgnored private nonisolated(unsafe) var liveTask: Task<Void, Never>?

    /// Line cap; beyond it the oldest lines drop, matching LogStore's ring.
    static let maxLines = 1000

    /// - Parameter store: injectable so tests can drive an isolated ring.
    public init(store: LogStore = .shared) {
        self.store = store
    }

    deinit {
        self.liveTask?.cancel()
    }

    /// Backfills the ring's `.presence` entries and follows the live stream.
    /// Call from the view's `.task`; runs until cancelled.
    public func start() {
        guard self.liveTask == nil else { return }
        let (backfill, live) = self.store.backfillAndSubscribe()
        self.ingest(backfill)
        self.flush()
        self.liveTask = Task {
            for await entry in live {
                self.ingest([entry])
                self.flush()
            }
        }
    }

    /// Stops following the live stream. Safe to call repeatedly.
    public func stop() {
        self.liveTask?.cancel()
        self.liveTask = nil
    }

    private func ingest(_ incoming: [LogEntry]) {
        for entry in incoming where entry.category == .presence {
            self.entries.append(entry)
            self.pending.append(entry)
        }
        if self.entries.count > Self.maxLines {
            self.entries.removeFirst(self.entries.count - Self.maxLines)
        }
    }

    private func flush() {
        guard !self.pending.isEmpty else { return }
        let lines = self.pending.map { entry in
            DebugPresenceLine(id: entry.id, timestamp: entry.timestamp, message: entry.message)
        }
        self.pending.removeAll()
        self.lines.append(contentsOf: lines)
        if self.lines.count > Self.maxLines {
            self.lines.removeFirst(self.lines.count - Self.maxLines)
        }
    }
}
