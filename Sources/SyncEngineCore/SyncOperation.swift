import Foundation

/// A field-level value that can travel through the sync pipeline without
/// pulling in `Any`/`NSObject`, so `SyncOperation` stays `Sendable` end to end.
public enum SyncValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case null
}

/// One durable, replayable unit of local change: "create/update/delete this
/// entity, with this payload, made by this device at this time."
///
/// This is deliberately *not* "the Core Data object itself." Managed objects
/// aren't Sendable and shouldn't cross actor boundaries. `SyncOperation` is
/// the value-type shadow of a change that the sync engine can hold, retry,
/// and reason about without ever touching `NSManagedObjectContext`.
public struct SyncOperation: Identifiable, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case create, update, delete
    }

    public let id: UUID
    public let entityID: String
    public let kind: Kind
    public let payload: [String: SyncValue]
    public let localTimestamp: Date
    public let deviceID: String
    public var retryCount: Int
    public var lastError: String?
    /// Backoff gate: the store won't surface this operation from
    /// `fetchPendingOperations()` again until this time has passed. `nil`
    /// means "eligible immediately" (a fresh operation, never yet retried).
    public var nextRetryAt: Date?

    public init(
        id: UUID = UUID(),
        entityID: String,
        kind: Kind,
        payload: [String: SyncValue],
        localTimestamp: Date = Date(),
        deviceID: String,
        retryCount: Int = 0,
        lastError: String? = nil,
        nextRetryAt: Date? = nil
    ) {
        self.id = id
        self.entityID = entityID
        self.kind = kind
        self.payload = payload
        self.localTimestamp = localTimestamp
        self.deviceID = deviceID
        self.retryCount = retryCount
        self.lastError = lastError
        self.nextRetryAt = nextRetryAt
    }

    /// Returns a copy with retry bookkeeping advanced. Used by `SyncManager`
    /// after a failed upload attempt; kept as a pure function so retry logic
    /// is trivially testable without a store round-trip.
    public func incrementingRetry(error: String, nextRetryAt: Date?) -> SyncOperation {
        var copy = self
        copy.retryCount += 1
        copy.lastError = error
        copy.nextRetryAt = nextRetryAt
        return copy
    }
}

/// The server's view of an entity at the moment a conflict was detected.
/// Kept minimal on purpose: the conflict resolver only ever needs "when" and
/// "who," never the full remote object graph.
public struct RemoteSnapshot: Sendable, Equatable, Codable {
    public let entityID: String
    public let remoteTimestamp: Date
    public let deviceID: String
    public let payload: [String: SyncValue]

    public init(entityID: String, remoteTimestamp: Date, deviceID: String, payload: [String: SyncValue]) {
        self.entityID = entityID
        self.remoteTimestamp = remoteTimestamp
        self.deviceID = deviceID
        self.payload = payload
    }
}

/// Thrown by a `RemoteAPIClient` when the server rejects an upload because
/// the entity changed remotely since the client last saw it.
public struct ConflictError: Error, Sendable {
    public let remoteSnapshot: RemoteSnapshot
    public init(remoteSnapshot: RemoteSnapshot) {
        self.remoteSnapshot = remoteSnapshot
    }
}
