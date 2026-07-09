import struct Foundation.UUID
import class Foundation.NSLock

/// Something that can emit "a local change happened" signals as an
/// `AsyncStream`. `SyncEngineCoreData` implements this over
/// `NSManagedObjectContextDidSave`; tests and previews use
/// `ManualChangeSignal` to trigger sync deterministically instead of
/// waiting on a real save notification.
public protocol ChangeObserving: Sendable {
    func changes() -> AsyncStream<Void>
}

/// A hand-crank version of change observation: call `signal()` and every
/// active `changes()` stream yields once. Exists so `SyncCoordinator` can be
/// tested and demoed without a real persistence layer wired in.
public final class ManualChangeSignal: ChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init() {}

    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    public func signal() {
        lock.lock()
        let current = continuations
        lock.unlock()
        for continuation in current.values {
            continuation.yield(())
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
