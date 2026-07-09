import Foundation

/// The network boundary. Everything above this protocol (SyncManager,
/// conflict resolution, retry policy) is written against it, never against
/// URLSession directly — which is what makes flaky-network behavior testable
/// without touching a real network.
public protocol RemoteAPIClient: Sendable {
    /// Uploads one operation. Throws `ConflictError` if the server's copy of
    /// the entity has moved since this operation's `localTimestamp`, or any
    /// other `Error` for a plain transient failure (timeout, 5xx, offline).
    func upload(_ operation: SyncOperation) async throws -> RemoteSnapshot
}

/// A network double that fails, delays, and conflicts on purpose. This is
/// the same client both `SyncEngineCoreTests` and the demo app's "chaos"
/// toggle use — one flaky-network implementation, exercised two ways.
public actor MockRemoteAPIClient: RemoteAPIClient {
    public struct Configuration: Sendable {
        /// Probability (0...1) that an upload fails with a transient error.
        public var failureRate: Double
        /// Probability (0...1) that an upload fails with a conflict instead.
        public var conflictRate: Double
        /// Simulated round-trip latency.
        public var latency: Duration
        /// Whether the "device" is currently offline — every upload fails
        /// immediately, no latency, no retry-eligible distinction.
        public var isOffline: Bool

        public init(
            failureRate: Double = 0.15,
            conflictRate: Double = 0.1,
            latency: Duration = .milliseconds(150),
            isOffline: Bool = false
        ) {
            self.failureRate = failureRate
            self.conflictRate = conflictRate
            self.latency = latency
            self.isOffline = isOffline
        }
    }

    public enum SimulatedError: Error, Sendable {
        case offline
        case timeout
        case serverError(Int)
    }

    private var configuration: Configuration
    /// The "server's" last known state per entity, so conflicts are
    /// internally consistent rather than random noise.
    private var remoteState: [String: RemoteSnapshot] = [:]
    private let deviceID: String

    public init(configuration: Configuration = Configuration(), remoteDeviceID: String = "server") {
        self.configuration = configuration
        self.deviceID = remoteDeviceID
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Lets the demo UI show what the server "thinks" an entity looks like,
    /// which is what the conflict-resolution screen compares against.
    public func remoteSnapshot(for entityID: String) -> RemoteSnapshot? {
        remoteState[entityID]
    }

    /// Test/demo hook to seed a divergent remote state before an upload, so
    /// a conflict can be triggered deterministically instead of by dice roll.
    public func seedRemoteState(_ snapshot: RemoteSnapshot) {
        remoteState[snapshot.entityID] = snapshot
    }

    public func upload(_ operation: SyncOperation) async throws -> RemoteSnapshot {
        if configuration.isOffline {
            throw SimulatedError.offline
        }

        try await Task.sleep(for: configuration.latency)

        if Double.random(in: 0...1) < configuration.conflictRate {
            let conflicting = RemoteSnapshot(
                entityID: operation.entityID,
                remoteTimestamp: Date(),
                deviceID: "another-device",
                payload: operation.payload
            )
            remoteState[operation.entityID] = conflicting
            throw ConflictError(remoteSnapshot: conflicting)
        }

        if Double.random(in: 0...1) < configuration.failureRate {
            throw SimulatedError.timeout
        }

        let snapshot = RemoteSnapshot(
            entityID: operation.entityID,
            remoteTimestamp: operation.localTimestamp,
            deviceID: operation.deviceID,
            payload: operation.payload
        )
        remoteState[operation.entityID] = snapshot
        return snapshot
    }
}
