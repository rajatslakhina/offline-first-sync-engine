import XCTest
@testable import SyncEngineCore

final class BackoffPolicyTests: XCTestCase {
    func test_delay_growsExponentiallyWithRetryCount() {
        let policy = BackoffPolicy(baseDelay: .seconds(1), maxDelay: .seconds(1000), jitter: 0)

        let delay0 = policy.delay(forRetryCount: 0).doubleSeconds
        let delay1 = policy.delay(forRetryCount: 1).doubleSeconds
        let delay2 = policy.delay(forRetryCount: 2).doubleSeconds

        XCTAssertEqual(delay0, 1, accuracy: 0.01)
        XCTAssertEqual(delay1, 2, accuracy: 0.01)
        XCTAssertEqual(delay2, 4, accuracy: 0.01)
    }

    func test_delay_isCappedAtMaxDelay() {
        let policy = BackoffPolicy(baseDelay: .seconds(1), maxDelay: .seconds(10), jitter: 0)

        let delay = policy.delay(forRetryCount: 20).doubleSeconds // 2^20 seconds uncapped — must be clamped

        XCTAssertEqual(delay, 10, accuracy: 0.01)
    }

    func test_delay_withJitter_staysWithinExpectedRange() {
        let policy = BackoffPolicy(baseDelay: .seconds(10), maxDelay: .seconds(1000), jitter: 0.5)

        for _ in 0..<50 {
            let delay = policy.delay(forRetryCount: 0).doubleSeconds
            XCTAssertGreaterThanOrEqual(delay, 5, "jittered delay fell below the documented ±50% band")
            XCTAssertLessThanOrEqual(delay, 15, "jittered delay exceeded the documented ±50% band")
        }
    }

    func test_delay_neverGoesNegative() {
        let policy = BackoffPolicy(baseDelay: .seconds(1), maxDelay: .seconds(10), jitter: 2.0) // deliberately extreme jitter

        for retryCount in 0..<10 {
            let delay = policy.delay(forRetryCount: retryCount).doubleSeconds
            XCTAssertGreaterThanOrEqual(delay, 0)
        }
    }
}
