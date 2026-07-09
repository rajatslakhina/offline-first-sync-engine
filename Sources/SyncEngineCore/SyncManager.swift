import Foundation

/// Outcome of one `sync()` pass, surfaced to the UI so it can show something
/// better than a spinner that never explains itself.
public struct SyncResult: Sendable, Equatable {
    public let succeeded: Int
    public let failed: Int
    public let conflicts: Int
    public let awaitingUserDecision: Int

    public static let alreadyInProgress = SyncResult(succeeded: 0, failed: 0, conflicts: 0, awaitingUserDecision: 0)

    public init(succeeded: Int, failed: Int, conflicts: Int, awaitingUserDecision: Int) {
        self.succeeded = succeeded
        self.failed = failed
        self.conflicts = conflicts
        self.awaitingUserDecision = awaitingUserDecision
    }
}

/// The single actor that owns sync coordination, matching the source
/// article's core rule: **one actor owns sync coordination**, and nothing
/// else is allowed to touch the network on its behalf.
///
/// Why an actor and not a plain class with a lock: the failure mode we're
/// defending against isn't a data race in the Swift-memory-model sense —
/// it's *logical* double-syncing (two overlapping `sync()` calls both
/// reading "pending operations," both uploading the same row, one of them
/// racing a `markSynced` against the other's retry). An actor gives us
/// exclusive access to `isSyncing` and the upload loop for free, so that
/// failure mode is structurally impossible rather than "unlikely."
public actor SyncManager {
    private let store: any PendingOperationStore
    private let api: any RemoteAPIClient
    private let conflictResolver: any ConflictResolving
    private let backoffPolicy: BackoffPolicy
    private let maxRetries: Int
    private var isSyncing = false

    public private(set) var lastResult: SyncResult?

    public init(
        store: any PendingOperationStore,
        api: any RemoteAPIClient,
        conflictResolver: any ConflictResolving,
        backoffPolicy: BackoffPolicy = BackoffPolicy(),
        maxRetries: Int = 3
    ) {
        self.store = store
        self.api = api
        self.conflictResolver = conflictResolver
        self.backoffPolicy = backoffPolicy
        self.maxRetries = maxRetries
    }

    /// Drains the pending-operation queue once. Safe to call as often as
    /// you like — including "on every AsyncStream change signal" — because
    /// a call that arrives while one is already running is a no-op rather
    /// than a second concurrent pass.
    @discardableResult
    public func sync() async -> SyncResult {
        guard !isSyncing else { return .alreadyInProgress }
        isSyncing = true
        defer { isSyncing = false }

        let pending = await store.fetchPendingOperations()
        var succeeded = 0
        var failed = 0
        var conflicts = 0
        var awaitingDecision = 0

        for operation in pending {
            do {
                _ = try await api.upload(operation)
                await store.markSynced(operation.id)
                succeeded += 1
            } catch let conflict as ConflictError {
                conflicts += 1
                await handle(conflict, for: operation, awaitingDecision: &awaitingDecision, failed: &failed)
            } catch {
                failed += 1
                await handleTransientFailure(operation, error: error)
            }
        }

        let result = SyncResult(
            succeeded: succeeded,
            failed: failed,
            conflicts: conflicts,
            awaitingUserDecision: awaitingDecision
        )
        lastResult = result
        return result
    }

    private func handle(
        _ conflict: ConflictError,
        for operation: SyncOperation,
        awaitingDecision: inout Int,
        failed: inout Int
    ) async {
        let resolution = await conflictResolver.resolve(local: operation, remote: conflict.remoteSnapshot)
        switch resolution {
        case .acceptLocal:
            // The resolver decided our copy should win despite the server's
            // objection — re-enqueue for the next pass rather than looping
            // an upload inline, so a persistently-conflicting operation
            // still respects the same retry/backoff bookkeeping as any
            // other failure instead of spinning synchronously forever.
            let retryAt = Date().addingTimeInterval(
                backoffPolicy.delay(forRetryCount: operation.retryCount).doubleSeconds
            )
            await store.markFailed(operation.id, error: "conflict:acceptLocal:retry-next-pass", nextRetryAt: retryAt)
            failed += 1
        case .acceptRemote:
            // The server's copy wins outright: drop our local operation.
            await store.remove(operation.id)
        case .requiresUserDecision:
            await store.markAwaitingUserDecision(operation.id)
            awaitingDecision += 1
        }
    }

    private func handleTransientFailure(_ operation: SyncOperation, error: Error) async {
        if operation.retryCount >= maxRetries {
            // Past the retry ceiling: park it (nextRetryAt = .distantFuture)
            // rather than deleting it. A silently-dropped write is exactly
            // the "lost data" failure mode the source article calls out —
            // this operation stays visible to the UI as "needs attention"
            // instead of vanishing.
            await store.markFailed(
                operation.id,
                error: "max retries exceeded: \(error)",
                nextRetryAt: .distantFuture
            )
        } else {
            let retryAt = Date().addingTimeInterval(
                backoffPolicy.delay(forRetryCount: operation.retryCount).doubleSeconds
            )
            await store.markFailed(operation.id, error: "\(error)", nextRetryAt: retryAt)
        }
    }
}
