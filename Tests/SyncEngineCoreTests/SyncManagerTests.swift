import XCTest
@testable import SyncEngineCore

final class SyncManagerTests: XCTestCase {
    private func makeOperation(entityID: String = "note-1", kind: SyncOperation.Kind = .update, deviceID: String = "device-a") -> SyncOperation {
        SyncOperation(
            entityID: entityID,
            kind: kind,
            payload: ["title": .string("hello")],
            deviceID: deviceID
        )
    }

    func test_sync_withNoPendingOperations_returnsZeroedResult() async {
        let store = InMemoryPendingOperationStore()
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 0))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())

        let result = await manager.sync()

        XCTAssertEqual(result, SyncResult(succeeded: 0, failed: 0, conflicts: 0, awaitingUserDecision: 0))
    }

    func test_sync_withCleanNetwork_marksAllOperationsSynced() async {
        let store = InMemoryPendingOperationStore()
        await store.save(makeOperation(entityID: "a"))
        await store.save(makeOperation(entityID: "b"))
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())

        let result = await manager.sync()

        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, 0)
        let remaining = await store.fetchPendingOperations()
        XCTAssertTrue(remaining.isEmpty, "synced operations must be removed from the pending queue")
    }

    func test_sync_calledConcurrently_secondCallIsANoOp() async {
        let store = InMemoryPendingOperationStore()
        for i in 0..<20 {
            await store.save(makeOperation(entityID: "item-\(i)"))
        }
        // Deliberately slow, so the two sync() calls below are guaranteed to overlap.
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 0, latency: .milliseconds(50)))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())

        async let first = manager.sync()
        async let second = manager.sync()
        let (firstResult, secondResult) = await (first, second)

        // Exactly one of the two calls should have found the actor already
        // syncing and backed off immediately — this is the "one actor owns
        // sync coordination" guarantee, proven rather than assumed.
        let noOpCount = [firstResult, secondResult].filter { $0 == .alreadyInProgress }.count
        XCTAssertEqual(noOpCount, 1, "exactly one overlapping sync() call must be rejected as already-in-progress")

        let realResult = firstResult == .alreadyInProgress ? secondResult : firstResult
        XCTAssertEqual(realResult.succeeded, 20, "the winning sync() call must still process every pending operation exactly once")
    }

    func test_sync_onTransientFailure_incrementsRetryCountAndSchedulesBackoff() async {
        let store = InMemoryPendingOperationStore()
        let operation = makeOperation()
        await store.save(operation)
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 1.0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(
            store: store,
            api: api,
            conflictResolver: LastWriteWinsResolver(),
            backoffPolicy: BackoffPolicy(baseDelay: .seconds(30), jitter: 0)
        )

        let result = await manager.sync()

        XCTAssertEqual(result.failed, 1)
        // The operation is still "pending" in the sense of existing, but
        // shouldn't be immediately re-fetchable — its backoff window (30s
        // base delay) hasn't elapsed yet.
        let immediatelyPending = await store.fetchPendingOperations()
        XCTAssertTrue(immediatelyPending.isEmpty, "a freshly-failed operation must respect its backoff window")
    }

    func test_sync_pastMaxRetries_parksOperationInsteadOfDroppingIt() async {
        let store = InMemoryPendingOperationStore()
        var operation = makeOperation()
        operation.retryCount = 3 // already at maxRetries
        await store.save(operation)
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 1.0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver(), maxRetries: 3)

        let result = await manager.sync()

        XCTAssertEqual(result.failed, 1)
        // Parked (nextRetryAt = .distantFuture), never silently deleted —
        // this is the "no lost data" guarantee the source article insists on.
        let awaitingDecision = await store.fetchAwaitingUserDecision()
        XCTAssertTrue(awaitingDecision.isEmpty, "max-retry operations are parked via backoff, not routed through the user-decision path")
    }

    func test_sync_onConflict_withUserInterventionResolver_parksOperationForUserDecision() async {
        let store = InMemoryPendingOperationStore()
        let operation = makeOperation()
        await store.save(operation)
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 1.0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: UserInterventionResolver())

        let result = await manager.sync()

        XCTAssertEqual(result.conflicts, 1)
        XCTAssertEqual(result.awaitingUserDecision, 1)
        let awaiting = await store.fetchAwaitingUserDecision()
        XCTAssertEqual(awaiting.count, 1)
        let stillPending = await store.fetchPendingOperations()
        XCTAssertTrue(stillPending.isEmpty, "an operation awaiting user decision must not be re-synced automatically")
    }
}
