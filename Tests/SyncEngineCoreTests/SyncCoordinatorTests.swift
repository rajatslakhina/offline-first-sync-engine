import XCTest
@testable import SyncEngineCore

final class SyncCoordinatorTests: XCTestCase {
    func test_signal_triggersSyncAndPublishesSyncedStatus() async throws {
        let store = InMemoryPendingOperationStore()
        await store.save(SyncOperation(entityID: "a", kind: .create, payload: [:], deviceID: "device-a"))
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())
        let signal = ManualChangeSignal()
        let coordinator = SyncCoordinator(syncManager: manager, changeObserver: signal)

        let statusStream = await coordinator.statusUpdates()
        await coordinator.start()

        var iterator = statusStream.makeAsyncIterator()

        signal.signal()

        // First published status after a signal should be `.syncing`...
        let syncingStatus = await iterator.next()
        XCTAssertEqual(syncingStatus, .syncing)

        // ...followed by `.synced` once the (fast, clean) mock API returns.
        let finalStatus = await iterator.next()
        guard case .synced = finalStatus else {
            XCTFail("expected .synced after a clean sync pass, got \(String(describing: finalStatus))")
            return
        }

        await coordinator.stop()
    }

    func test_withFailingOperations_publishesNeedsAttention() async throws {
        let store = InMemoryPendingOperationStore()
        await store.save(SyncOperation(entityID: "a", kind: .create, payload: [:], deviceID: "device-a"))
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 1.0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())
        let signal = ManualChangeSignal()
        let coordinator = SyncCoordinator(syncManager: manager, changeObserver: signal)

        let statusStream = await coordinator.statusUpdates()
        await coordinator.start()
        var iterator = statusStream.makeAsyncIterator()

        signal.signal()

        _ = await iterator.next() // .syncing
        let finalStatus = await iterator.next()

        guard case let .needsAttention(failed, conflicts, awaitingDecision) = finalStatus else {
            XCTFail("expected .needsAttention after every operation fails, got \(String(describing: finalStatus))")
            return
        }
        XCTAssertEqual(failed, 1)
        XCTAssertEqual(conflicts, 0)
        XCTAssertEqual(awaitingDecision, 0)

        await coordinator.stop()
    }

    func test_syncNow_worksWithoutAnyChangeSignal() async {
        let store = InMemoryPendingOperationStore()
        await store.save(SyncOperation(entityID: "a", kind: .create, payload: [:], deviceID: "device-a"))
        let api = MockRemoteAPIClient(configuration: .init(failureRate: 0, conflictRate: 0, latency: .zero))
        let manager = SyncManager(store: store, api: api, conflictResolver: LastWriteWinsResolver())
        let signal = ManualChangeSignal()
        let coordinator = SyncCoordinator(syncManager: manager, changeObserver: signal)

        // No start(), no signal — just the manual "Sync Now" button path.
        await coordinator.syncNow()

        let remaining = await store.fetchPendingOperations()
        XCTAssertTrue(remaining.isEmpty, "syncNow() must drain the queue exactly like a signal-triggered pass")
    }
}
