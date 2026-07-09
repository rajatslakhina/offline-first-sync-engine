#if canImport(CoreData)
import CoreData
import Foundation
import SyncEngineCore

/// Errors specific to the Core Data-backed pending operation store — kept
/// separate from `SyncEngineCore` since they're an implementation detail of
/// *this* persistence choice, not something the sync engine itself should
/// know exists.
enum CoreDataStoreError: Error {
    case payloadEncodingFailed
    case payloadDecodingFailed
}

/// The production `PendingOperationStore`. `SyncManager` never imports
/// `CoreData` and never will — this type is the only place in the whole
/// engine where `SyncOperation` (a plain, Sendable struct) gets translated
/// to and from `PendingOperationEntity` (a managed object, not Sendable,
/// context-bound).
///
/// Every method hops onto `context.perform` because `NSManagedObjectContext`
/// is not thread-safe to touch from just anywhere, actor or not — the actor
/// isolation on the caller (`SyncManager`) guarantees no *concurrent* calls
/// into this store, but it says nothing about which thread Core Data's
/// context expects to be used on.
/// `@unchecked Sendable`: every mutable access happens inside
/// `context.perform`, which serializes work onto the context's own private
/// queue — the same guarantee an actor gives you, just enforced by Core
/// Data's queue confinement instead of Swift's actor isolation checker.
public final class CoreDataPendingOperationStore: PendingOperationStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    public func fetchPendingOperations() async -> [SyncOperation] {
        await context.perform {
            let request = PendingOperationEntity.fetchRequest()
            let now = Date()
            request.predicate = NSPredicate(
                format: "awaitingUserDecision == NO AND (nextRetryAt == nil OR nextRetryAt <= %@)",
                now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(keyPath: \PendingOperationEntity.localTimestamp, ascending: true)]

            guard let results = try? self.context.fetch(request) else { return [] }
            return results.compactMap { self.toSyncOperation($0) }
        }
    }

    public func save(_ operation: SyncOperation) async {
        await context.perform {
            let entity = self.findOrCreate(operation.id)
            self.apply(operation, to: entity)
            self.trySave()
        }
    }

    public func markSynced(_ operationID: SyncOperation.ID) async {
        await context.perform {
            guard let entity = self.find(operationID) else { return }
            self.context.delete(entity)
            self.trySave()
        }
    }

    public func markFailed(_ operationID: SyncOperation.ID, error: String, nextRetryAt: Date?) async {
        await context.perform {
            guard let entity = self.find(operationID) else { return }
            entity.retryCount += 1
            entity.lastError = error
            entity.nextRetryAt = nextRetryAt
            self.trySave()
        }
    }

    public func remove(_ operationID: SyncOperation.ID) async {
        await context.perform {
            guard let entity = self.find(operationID) else { return }
            self.context.delete(entity)
            self.trySave()
        }
    }

    public func fetchAwaitingUserDecision() async -> [SyncOperation] {
        await context.perform {
            let request = PendingOperationEntity.fetchRequest()
            request.predicate = NSPredicate(format: "awaitingUserDecision == YES")
            guard let results = try? self.context.fetch(request) else { return [] }
            return results.compactMap { self.toSyncOperation($0) }
        }
    }

    public func markAwaitingUserDecision(_ operationID: SyncOperation.ID) async {
        await context.perform {
            guard let entity = self.find(operationID) else { return }
            entity.awaitingUserDecision = true
            self.trySave()
        }
    }

    // MARK: - Managed object <-> value type

    private func find(_ id: SyncOperation.ID) -> PendingOperationEntity? {
        let request = PendingOperationEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func findOrCreate(_ id: SyncOperation.ID) -> PendingOperationEntity {
        find(id) ?? PendingOperationEntity(context: context)
    }

    private func apply(_ operation: SyncOperation, to entity: PendingOperationEntity) {
        entity.id = operation.id
        entity.entityID = operation.entityID
        entity.kind = operation.kind.rawValue
        entity.payloadData = (try? JSONEncoder().encode(operation.payload)) ?? Data()
        entity.localTimestamp = operation.localTimestamp
        entity.deviceID = operation.deviceID
        entity.retryCount = Int32(operation.retryCount)
        entity.lastError = operation.lastError
        entity.nextRetryAt = operation.nextRetryAt
        // `save` always represents a live/eligible operation — see the
        // protocol doc comment on `PendingOperationStore.save`.
        entity.awaitingUserDecision = false
    }

    private func toSyncOperation(_ entity: PendingOperationEntity) -> SyncOperation? {
        guard
            let id = entity.id,
            let kind = SyncOperation.Kind(rawValue: entity.kind ?? ""),
            let payload = try? JSONDecoder().decode([String: SyncValue].self, from: entity.payloadData ?? Data()),
            let localTimestamp = entity.localTimestamp,
            let deviceID = entity.deviceID
        else {
            return nil
        }
        return SyncOperation(
            id: id,
            entityID: entity.entityID ?? "",
            kind: kind,
            payload: payload,
            localTimestamp: localTimestamp,
            deviceID: deviceID,
            retryCount: Int(entity.retryCount),
            lastError: entity.lastError,
            nextRetryAt: entity.nextRetryAt
        )
    }

    /// Centralizing save-and-log here means every write path gets the same
    /// treatment instead of six call sites each deciding independently
    /// whether a failed save deserves a crash, a silent drop, or a log line.
    /// For a POC, logging and continuing is the right trade-off — a
    /// production app would propagate this to a "storage degraded" signal
    /// the UI can show.
    private func trySave() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("CoreDataPendingOperationStore save failed: \(error)")
        }
    }
}
#endif
