#if canImport(CoreData)
import CoreData

/// Owns the `NSPersistentContainer` and hands out contexts. Nothing else in
/// this module (or the demo app) is allowed to construct its own container —
/// one stack, one source of truth for "what Core Data thinks reality is."
public final class CoreDataStack: @unchecked Sendable {
    public let container: NSPersistentContainer

    /// - Parameters:
    ///   - inMemory: `true` for previews/tests that want a fresh store every
    ///     launch with no disk I/O.
    public init(inMemory: Bool = false) {
        guard let modelURL = Bundle.module.url(forResource: "OfflineSyncModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("OfflineSyncModel.xcdatamodeld failed to load from the module bundle — check the Resources build phase.")
        }

        container = NSPersistentContainer(name: "OfflineSyncModel", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error {
                // A production app would surface this as a recoverable
                // "storage unavailable" state, not crash — but for a
                // demo/POC, failing loudly beats silently running with no
                // persistence and confusing whoever's reading the console.
                fatalError("Failed to load Core Data store \(description): \(error)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    public var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// A background context for the sync engine and repository writes, kept
    /// separate from `viewContext` so a long-running sync pass never blocks
    /// (or gets blocked by) SwiftUI's main-thread reads.
    public func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
}
#endif
