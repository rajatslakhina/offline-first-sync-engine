#if canImport(CoreData)
import CoreData
import SyncEngineCore

/// The production implementation of `ChangeObserving`: turns
/// `NSManagedObjectContextDidSave` into an `AsyncStream<Void>`, which is
/// exactly the pattern from the source article's "Listening to Data Changes
/// with AsyncStream" section — reacting to saves instead of polling or
/// requiring every call site to remember to kick off a sync manually.
public final class CoreDataChangeObserver: ChangeObserving, @unchecked Sendable {
    private let context: NSManagedObjectContext

    /// - Parameter context: typically the stack's `viewContext` — saves from
    ///   background contexts still surface here once merged, since the
    ///   stack sets `automaticallyMergesChangesFromParent`.
    public init(context: NSManagedObjectContext) {
        self.context = context
    }

    public func changes() -> AsyncStream<Void> {
        let coordinator = context.persistentStoreCoordinator
        return AsyncStream { continuation in
            // object: nil (rather than object: context) is deliberate — we
            // want saves from *background* contexts too (that's how the
            // repository writes), not just the view context. We filter by
            // persistent store coordinator instead, so a save on some
            // unrelated Core Data stack elsewhere in the process (a second
            // stack in tests, say) can't spuriously trigger a sync pass.
            let observer = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: nil,
                queue: nil
            ) { notification in
                guard let savedContext = notification.object as? NSManagedObjectContext,
                      savedContext.persistentStoreCoordinator === coordinator else {
                    return
                }
                continuation.yield(())
            }

            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
#endif
