import Foundation

/// What to do once a conflict has been classified.
public enum ConflictResolution: Sendable, Equatable {
    /// Push the local change again, treating it as the winner.
    case acceptLocal
    /// Drop the local change; the remote value already reflects reality.
    case acceptRemote
    /// Neither side gets to decide automatically — park it and ask the user.
    case requiresUserDecision
}

/// How sensitive a field is to silently losing a write. This is a product
/// decision, not a technical one — see the "Our Strategy" section of the
/// source article. A financial balance and a note's "last viewed" timestamp
/// do not deserve the same conflict-handling rigor.
public enum FieldSensitivity: Sendable, Equatable {
    /// Fine to silently overwrite — last write wins.
    case nonDestructive
    /// Overwriting risks real user harm (money, deletions, anything
    /// irreversible) — never resolve this automatically.
    case destructive
}

public protocol ConflictResolving: Sendable {
    func resolve(local: SyncOperation, remote: RemoteSnapshot) async -> ConflictResolution
}

/// Resolves purely by comparing timestamps. Correct only for fields where
/// losing a write silently is an acceptable trade-off.
public struct LastWriteWinsResolver: ConflictResolving {
    public init() {}

    public func resolve(local: SyncOperation, remote: RemoteSnapshot) async -> ConflictResolution {
        local.localTimestamp >= remote.remoteTimestamp ? .acceptLocal : .acceptRemote
    }
}

/// Never resolves automatically. Used for destructive/irreversible
/// operations (deletes, financial fields) where a silently-applied "winner"
/// is worse than asking.
public struct UserInterventionResolver: ConflictResolving {
    public init() {}

    public func resolve(local: SyncOperation, remote: RemoteSnapshot) async -> ConflictResolution {
        .requiresUserDecision
    }
}

/// Breaks timestamp ties (same-second edits from two devices are common
/// with optimistic UI) using device identity as the tiebreaker, then falls
/// back to last-write-wins.
public struct DeviceTimestampPrecedenceResolver: ConflictResolving {
    private let precedenceDeviceID: String

    /// - Parameter precedenceDeviceID: the device that wins ties. In the
    ///   demo this is fixed for determinism; in production you'd typically
    ///   use a stable per-user "primary device" or the account creation
    ///   device rather than picking a client at random.
    public init(precedenceDeviceID: String) {
        self.precedenceDeviceID = precedenceDeviceID
    }

    public func resolve(local: SyncOperation, remote: RemoteSnapshot) async -> ConflictResolution {
        let delta = abs(local.localTimestamp.timeIntervalSince(remote.remoteTimestamp))
        guard delta < 1.0 else {
            return local.localTimestamp >= remote.remoteTimestamp ? .acceptLocal : .acceptRemote
        }
        return local.deviceID == precedenceDeviceID ? .acceptLocal : .acceptRemote
    }
}

/// Routes each operation to the right strategy based on how sensitive its
/// fields are, instead of applying one resolver to every conflict in the
/// app. This is the resolver `SyncManager` is actually configured with —
/// the three resolvers above are its building blocks, not standalone
/// production configurations.
public struct HybridConflictResolver: ConflictResolving {
    private let classify: @Sendable (SyncOperation) -> FieldSensitivity
    private let lastWriteWins: LastWriteWinsResolver
    private let userIntervention: UserInterventionResolver
    private let devicePrecedence: DeviceTimestampPrecedenceResolver

    public init(
        precedenceDeviceID: String,
        classify: @escaping @Sendable (SyncOperation) -> FieldSensitivity
    ) {
        self.classify = classify
        self.lastWriteWins = LastWriteWinsResolver()
        self.userIntervention = UserInterventionResolver()
        self.devicePrecedence = DeviceTimestampPrecedenceResolver(precedenceDeviceID: precedenceDeviceID)
    }

    public func resolve(local: SyncOperation, remote: RemoteSnapshot) async -> ConflictResolution {
        // Deletes are always irreversible regardless of field classification.
        if local.kind == .delete {
            return await userIntervention.resolve(local: local, remote: remote)
        }

        switch classify(local) {
        case .destructive:
            return await userIntervention.resolve(local: local, remote: remote)
        case .nonDestructive:
            if local.deviceID != remote.deviceID {
                return await devicePrecedence.resolve(local: local, remote: remote)
            }
            return await lastWriteWins.resolve(local: local, remote: remote)
        }
    }
}
