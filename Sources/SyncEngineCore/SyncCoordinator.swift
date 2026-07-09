import Foundation

/// What the UI actually wants to know, distilled from `SyncResult` history.
/// Deliberately does not expose `SyncManager` or `PendingOperationStore`
/// directly to SwiftUI — the article's rule is "SwiftUI never talks to the
/// network," and that includes not handing views a reference to anything
/// that could.
public enum SyncStatus: Sendable, Equatable {
    case idle
    case syncing
    case synced(at: Date)
    case needsAttention(failed: Int, conflicts: Int, awaitingDecision: Int)
}

/// Reacts to local-change signals by triggering a sync pass, and republishes
/// the result as a `SyncStatus` stream a SwiftUI view can bind to.
///
/// This is the piece that turns "listen to Core Data saves with
/// AsyncStream" (the article's section 2) and "one actor owns sync
/// coordination" (section 3) into one reactive pipeline instead of two
/// disconnected mechanisms a caller has to wire together by hand.
public actor SyncCoordinator {
    private let syncManager: SyncManager
    private let changeObserver: any ChangeObserving
    private var statusContinuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private var observationTask: Task<Void, Never>?

    public init(syncManager: SyncManager, changeObserver: any ChangeObserving) {
        self.syncManager = syncManager
        self.changeObserver = changeObserver
    }

    /// Subscribe to status updates. Each caller gets its own stream; the
    /// coordinator fans out one sync result to every subscriber (multiple
    /// SwiftUI views can watch the same coordinator).
    public func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            let id = UUID()
            statusContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    /// Starts listening for change signals and triggering sync passes.
    /// Idempotent — calling it twice doesn't spawn a second observation loop.
    ///
    /// `changeObserver.changes()` is called here, synchronously, before the
    /// child `Task` is spawned — not inside the task body. That ordering
    /// matters: it guarantees the underlying stream (and, for
    /// `ManualChangeSignal`/`NotificationCenter`-backed observers, its
    /// subscription) exists before `start()` returns, so a signal that
    /// fires immediately after `start()` can never be silently missed
    /// while a spawned task is still waiting for its turn on the executor.
    public func start() {
        guard observationTask == nil else { return }
        let stream = changeObserver.changes()
        observationTask = Task { [weak self] in
            for await _ in stream {
                await self?.runSyncAndPublish()
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Manual trigger for a "Sync Now" button, independent of the
    /// change-observation loop.
    public func syncNow() async {
        await runSyncAndPublish()
    }

    private func runSyncAndPublish() async {
        publish(.syncing)
        let result = await syncManager.sync()
        if result == .alreadyInProgress {
            return
        }
        if result.failed > 0 || result.conflicts > 0 || result.awaitingUserDecision > 0 {
            publish(.needsAttention(
                failed: result.failed,
                conflicts: result.conflicts,
                awaitingDecision: result.awaitingUserDecision
            ))
        } else {
            publish(.synced(at: Date()))
        }
    }

    private func publish(_ status: SyncStatus) {
        for continuation in statusContinuations.values {
            continuation.yield(status)
        }
    }

    private func removeContinuation(_ id: UUID) {
        statusContinuations.removeValue(forKey: id)
    }
}
