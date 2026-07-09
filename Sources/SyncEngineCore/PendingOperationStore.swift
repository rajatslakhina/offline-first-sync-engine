import Foundation

/// Durable storage for operations waiting to sync. `SyncManager` only ever
/// talks to this protocol, never to Core Data directly — that's what lets
/// the entire coordination/retry/conflict logic in this module run and be
/// unit-tested on Linux, with `SyncEngineCoreData` supplying the real
/// on-device implementation.
public protocol PendingOperationStore: Sendable {
    /// Returns operations that are both un-synced and past their backoff
    /// window (`nextRetryAt == nil || nextRetryAt <= now`).
    func fetchPendingOperations() async -> [SyncOperation]
    /// (Re)enqueues an operation as eligible for sync. Always clears any
    /// "awaiting user decision" park — `save` represents "this operation is
    /// live again," whether it's brand new or a resolved conflict being
    /// retried, so a caller can't accidentally leave a stale operation
    /// parked forever by calling `save` on it directly.
    func save(_ operation: SyncOperation) async
    func markSynced(_ operationID: SyncOperation.ID) async
    func markFailed(_ operationID: SyncOperation.ID, error: String, nextRetryAt: Date?) async
    func remove(_ operationID: SyncOperation.ID) async
    /// Operations that hit `requiresUserDecision` and are parked awaiting
    /// the user picking "keep mine" / "keep server's" in the UI.
    func fetchAwaitingUserDecision() async -> [SyncOperation]
    /// Parks an operation pending a user decision instead of retrying it
    /// automatically. Called by `SyncManager` when a conflict resolver
    /// returns `.requiresUserDecision`.
    func markAwaitingUserDecision(_ operationID: SyncOperation.ID) async
}

/// In-memory reference implementation. Used by the test suite, and by the
/// demo app's SwiftUI previews. Not a stand-in for Core Data in production —
/// see `CoreDataPendingOperationStore` in `SyncEngineCoreData` for that.
public actor InMemoryPendingOperationStore: PendingOperationStore {
    private var operations: [SyncOperation.ID: SyncOperation] = [:]
    private var awaitingDecision: Set<SyncOperation.ID> = []

    public init() {}

    public func fetchPendingOperations() async -> [SyncOperation] {
        let now = Date()
        return operations.values
            .filter { !awaitingDecision.contains($0.id) }
            .filter { ($0.nextRetryAt ?? .distantPast) <= now }
            .sorted { $0.localTimestamp < $1.localTimestamp }
    }

    public func save(_ operation: SyncOperation) async {
        operations[operation.id] = operation
        awaitingDecision.remove(operation.id)
    }

    public func markSynced(_ operationID: SyncOperation.ID) async {
        operations.removeValue(forKey: operationID)
        awaitingDecision.remove(operationID)
    }

    public func markFailed(_ operationID: SyncOperation.ID, error: String, nextRetryAt: Date?) async {
        guard let existing = operations[operationID] else { return }
        operations[operationID] = existing.incrementingRetry(error: error, nextRetryAt: nextRetryAt)
    }

    public func remove(_ operationID: SyncOperation.ID) async {
        operations.removeValue(forKey: operationID)
        awaitingDecision.remove(operationID)
    }

    public func fetchAwaitingUserDecision() async -> [SyncOperation] {
        operations.values.filter { awaitingDecision.contains($0.id) }
    }

    public func markAwaitingUserDecision(_ operationID: SyncOperation.ID) async {
        awaitingDecision.insert(operationID)
    }
}
