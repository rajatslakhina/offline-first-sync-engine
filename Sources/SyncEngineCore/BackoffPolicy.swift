import Foundation

/// Exponential backoff with jitter for retrying failed uploads. A fixed
/// retry interval is what turns "the network hiccuped" into "twenty clients
/// hammer the API in lockstep every five seconds" — jitter exists
/// specifically to break that lockstep.
public struct BackoffPolicy: Sendable {
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var jitter: Double

    public init(
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(60),
        jitter: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Delay before retry attempt `retryCount` (0-indexed: the first retry
    /// after an initial failure is `retryCount == 0`).
    public func delay(forRetryCount retryCount: Int) -> Duration {
        let baseSeconds = baseDelay.components.seconds
        let exponential = Double(baseSeconds) * pow(2.0, Double(retryCount))
        let maxSeconds = Double(maxDelay.components.seconds)
        let capped = min(exponential, maxSeconds)
        let jitterRange = capped * jitter
        let jittered = capped + Double.random(in: -jitterRange...jitterRange)
        return .seconds(max(0, jittered))
    }
}

extension Duration {
    /// Convenience conversion used when scheduling `Date`-based deadlines
    /// (`nextRetryAt`) from a `Duration`, since `Date` doesn't speak `Duration`.
    public var doubleSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
