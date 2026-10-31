import Foundation

/// The reconnect ladder of contract section 5: delays of 1.5 s, 3 s, 6 s, 12 s,
/// 24 s, capped at 30 s, each with ±20 % jitter. Reset after success; stops
/// while the peer is gone and resumes when it reappears.
public struct BackoffSchedule: Sendable {
    /// The unjittered ladder steps. Index 0 is the first retry.
    public let steps: [TimeInterval]
    /// The cap the ladder settles on after `steps` is exhausted.
    public let cap: TimeInterval
    /// Half-width of the jitter band, as a fraction (0.2 = ±20 %).
    public let jitterFraction: Double

    public init(
        steps: [TimeInterval] = [1.5, 3, 6, 12, 24],
        cap: TimeInterval = 30,
        jitterFraction: Double = 0.2
    ) {
        self.steps = steps
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    public static let `default` = Self()

    /// The unjittered base for `attempt` (0-based). Pure; tests pin the ladder.
    public func baseDelay(attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return self.cap }
        guard attempt < self.steps.count else { return self.cap }
        return self.steps[attempt]
    }

    /// The delay for `attempt` with a fixed jitter value in `-1...1`
    /// (-1 = full early, +1 = full late). Pure; tests pin the band edges.
    public func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let clamped = min(max(jitter, -1), 1)
        let base = self.baseDelay(attempt: attempt)
        return base * (1 + self.jitterFraction * clamped)
    }

    /// The delay for `attempt` with random jitter.
    public func randomDelay(attempt: Int) -> TimeInterval {
        self.delay(attempt: attempt, jitter: Double.random(in: -1 ... 1))
    }
}
