#if canImport(CoreData)
import CoreData
import Foundation
import SyncEngineCore

/// A note as the UI/ViewModel layer sees it — a plain, Sendable value, never
/// the managed object itself. This is the "Repository (read/write boundary)"
/// layer from the article's visual cheat sheet: everything above this type
/// only ever sees `Note` structs, never `NoteEntity`.
public struct Note: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var body: String
    public var updatedAt: Date
    public var syncStatus: SyncStatusLabel

    public init(id: UUID = UUID(), title: String, body: String, updatedAt: Date = Date(), syncStatus: SyncStatusLabel = .pending) {
        self.id = id
        self.title = title
        self.body = body
        self.updatedAt = updatedAt
        self.syncStatus = syncStatus
    }
}

/// Per-item status the list view badges each row with. Distinct from the
/// engine-wide `SyncStatus` in `SyncEngineCore` — that one describes "is the
/// coordinator syncing right now," this one describes "did *this specific
/// note's* last write make it to the server."
public enum SyncStatusLabel: String, Sendable, Equatable {
    case pending, synced, conflict, failed
}

/// The repository is the only thing allowed to touch `NoteEntity` directly.
/// It enforces the article's non-negotiable rule — **the local database is
/// the source of truth** — by always writing to Core Data first,
/// synchronously as far as the caller is concerned, and only *afterward*
/// enqueuing a `SyncOperation` for the engine to push out whenever the
/// network cooperates. The caller never waits on the network to get a
/// successful `save()`/`update()`/`delete()` return.
public final class NoteRepository: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let pendingStore: any PendingOperationStore
    private let deviceID: String

    public init(context: NSManagedObjectContext, pendingStore: any PendingOperationStore, deviceID: String) {
        self.context = context
        self.pendingStore = pendingStore
        self.deviceID = deviceID
    }

    public func fetchAll() async -> [Note] {
        await context.perform {
            let request = NoteEntity.fetchRequest()
            request.predicate = NSPredicate(format: "isDeleted == NO")
            request.sortDescriptors = [NSSortDescriptor(keyPath: \NoteEntity.updatedAt, ascending: false)]
            guard let results = try? self.context.fetch(request) else { return [] }
            return results.compactMap(self.toNote)
        }
    }

    /// Optimistic create: the note exists in the UI's next read the instant
    /// this returns, regardless of network state. The corresponding
    /// `SyncOperation` is queued in the same Core Data save, not as a
    /// follow-up step that could get lost if the app is killed in between.
    @discardableResult
    public func create(title: String, body: String) async -> Note {
        let note = Note(title: title, body: body)
        await context.perform {
            let entity = NoteEntity(context: self.context)
            entity.id = note.id
            entity.title = title
            entity.body = body
            entity.updatedAt = note.updatedAt
            entity.deviceID = self.deviceID
            entity.isDeleted = false
            entity.syncStatus = SyncStatusLabel.pending.rawValue
            try? self.context.save()
        }
        await enqueue(kind: .create, note: note)
        return note
    }

    public func update(_ note: Note) async {
        var updated = note
        updated.updatedAt = Date()
        await context.perform {
            guard let entity = self.findEntity(note.id) else { return }
            entity.title = updated.title
            entity.body = updated.body
            entity.updatedAt = updated.updatedAt
            entity.syncStatus = SyncStatusLabel.pending.rawValue
            try? self.context.save()
        }
        await enqueue(kind: .update, note: updated)
    }

    /// Soft delete: flips `isDeleted` rather than removing the row, so a
    /// user-intervention conflict (delete vs. concurrent edit) still has
    /// both sides of the story available to show in the resolution UI.
    /// The row is only actually removed once the delete syncs successfully.
    public func delete(_ noteID: UUID) async {
        var payload: [String: SyncValue] = [:]
        await context.perform {
            guard let entity = self.findEntity(noteID) else { return }
            entity.isDeleted = true
            entity.updatedAt = Date()
            entity.syncStatus = SyncStatusLabel.pending.rawValue
            payload = ["title": .string(entity.title ?? "")]
            try? self.context.save()
        }
        let operation = SyncOperation(
            entityID: noteID.uuidString,
            kind: .delete,
            payload: payload,
            deviceID: deviceID
        )
        await pendingStore.save(operation)
    }

    /// Called by the ViewModel after a sync pass, to reflect per-note
    /// outcomes (synced / conflict / failed) back into Core Data so the list
    /// UI's badges stay accurate.
    public func updateSyncStatus(noteID: UUID, status: SyncStatusLabel) async {
        await context.perform {
            guard let entity = self.findEntity(noteID) else { return }
            entity.syncStatus = status.rawValue
            try? self.context.save()
        }
    }

    // MARK: - Private

    private func findEntity(_ id: UUID) -> NoteEntity? {
        let request = NoteEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    private func toNote(_ entity: NoteEntity) -> Note? {
        guard let id = entity.id, let updatedAt = entity.updatedAt else { return nil }
        return Note(
            id: id,
            title: entity.title ?? "",
            body: entity.body ?? "",
            updatedAt: updatedAt,
            syncStatus: SyncStatusLabel(rawValue: entity.syncStatus ?? "pending") ?? .pending
        )
    }

    private func enqueue(kind: SyncOperation.Kind, note: Note) async {
        let payload: [String: SyncValue] = [
            "title": .string(note.title),
            "body": .string(note.body)
        ]
        let operation = SyncOperation(
            entityID: note.id.uuidString,
            kind: kind,
            payload: payload,
            localTimestamp: note.updatedAt,
            deviceID: deviceID
        )
        await pendingStore.save(operation)
    }
}
#endif
