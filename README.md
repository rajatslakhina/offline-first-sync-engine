# OfflineSyncEngine

A production-shaped implementation of the offline-first architecture described in [**Designing Offline-First Architecture with Swift Concurrency and Core Data Sync**](https://medium.com/@er.rajatlakhina/designing-offline-first-architecture-with-swift-concurrency-and-core-data-sync-46ad5008c7b5) — an actor-based sync coordinator, `AsyncStream`-driven reactive sync, exponential backoff, and a hybrid conflict-resolution strategy (last-write-wins for non-destructive fields, mandatory user intervention for deletes and destructive fields).

The runnable app that consumes this package lives in a separate repo: [**offline-first-sync-engine-demo**](https://github.com/rajatslakhina/offline-first-sync-engine-demo).

![Architecture: SwiftUI View → ViewModel → Repository → Core Data (source of truth) ↔ Sync Engine (Actor) ↔ Remote API, with an AsyncStream change signal from Core Data into the sync engine and conflict routing to a user-decision sheet](offline_sync_architecture.png)

## Why this exists

The source article makes one rule non-negotiable: **the local database is the source of truth, not the server.** Everything here follows from that. SwiftUI never talks to the network. The UI only reads from Core Data. One actor owns sync coordination. This package is that rule, written down as actual types instead of a diagram.

## Package layout

This is two libraries, not one, on purpose:

- **`SyncEngineCore`** — the actor, the retry/backoff policy, the conflict-resolution strategies, and the protocols (`PendingOperationStore`, `RemoteAPIClient`, `ChangeObserving`) everything else is built against. Zero platform dependencies. No `import CoreData`, no `import SwiftUI`, nothing that only exists on Apple platforms. This is what makes the sync/retry/conflict logic — the actual hard part of an offline-first system — unit-testable in CI on Linux, not just "testable in theory once you have a Simulator."
- **`SyncEngineCoreData`** — the real, on-device implementation: `CoreDataStack`, a `CoreDataChangeObserver` built on `NSManagedObjectContextDidSave` (the exact pattern from the article's "Listening to Data Changes with AsyncStream" section), `CoreDataPendingOperationStore`, and `NoteRepository` — the read/write boundary the article's diagram calls "Repository."

```
Sources/
  SyncEngineCore/       ← platform-agnostic. Builds + tests on Linux.
  SyncEngineCoreData/    ← Core Data-backed. Apple platforms only.
Tests/
  SyncEngineCoreTests/   ← 21 tests, all against SyncEngineCore.
```

## The actor

```swift
public actor SyncManager {
    public func sync() async -> SyncResult {
        guard !isSyncing else { return .alreadyInProgress }
        isSyncing = true
        defer { isSyncing = false }

        let pending = await store.fetchPendingOperations()
        for operation in pending {
            do {
                _ = try await api.upload(operation)
                await store.markSynced(operation.id)
            } catch let conflict as ConflictError {
                await handle(conflict, for: operation, ...)
            } catch {
                await handleTransientFailure(operation, error: error)
            }
        }
        ...
    }
}
```

`test_sync_calledConcurrently_secondCallIsANoOp` proves — not assumes — that two overlapping `sync()` calls never both walk the pending queue: exactly one gets rejected as already-in-progress, and the winning call still processes every operation exactly once.

## Conflict resolution

Matches the article's classification directly:

| Field type | Strategy | Resolver |
|---|---|---|
| Non-destructive (title, body edits) | Last-write-wins, device-precedence tiebreak on near-simultaneous edits | `LastWriteWinsResolver` / `DeviceTimestampPrecedenceResolver` |
| Destructive / irreversible (deletes, financial) | Never resolved automatically | `UserInterventionResolver` |

`HybridConflictResolver` routes each operation to the right one — and unconditionally routes every `.delete` operation through user intervention regardless of how a field classifier labels it, because a delete is irreversible by definition.

## Backoff

`BackoffPolicy` is real exponential backoff with jitter (base delay × 2^retryCount, capped, ±jitter to avoid retry lockstep across clients), not a fixed retry interval. Operations past `maxRetries` are parked (`nextRetryAt = .distantFuture`), never silently dropped — a silently-dropped write is exactly the "lost data" failure mode the source article is about.

## Verification

- **`SyncEngineCore`**: `swift build --target SyncEngineCore` and `swift test --filter SyncEngineCoreTests` both pass — **21/21 tests green** — on a headless Linux Swift 5.10.1 toolchain. Coverage: sync dedupe under concurrency, clean-network success path, transient-failure retry + backoff scheduling, max-retry parking, all three conflict resolvers plus the hybrid router (including the delete-override rule), `SyncCoordinator`'s reactive signal → sync → status-publish pipeline, and `BackoffPolicy`'s exponential growth/cap/jitter bounds.
- **`SyncEngineCoreData`**: Core Data isn't available on Linux, so this target compiles to an empty shell in the headless environment (guarded behind `#if canImport(CoreData)`) rather than actually building. It was verified by full manual read-through against the crash classes the test suite targets for `SyncEngineCore` (force-unwraps, unchecked array access, retain cycles), plus a scripted brace/paren balance check across every `.swift` file (all 25 files, balanced) and the hand-authored `.xcdatamodeld`. **This has not been confirmed to compile in Xcode** — that check needs a human with Xcode to do it. Flagging this honestly rather than claiming a build pass that didn't happen.

```
21 tests, 0 failures — SyncManagerTests (6), ConflictResolutionTests (8),
BackoffPolicyTests (4), SyncCoordinatorTests (3)
```

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/offline-first-sync-engine.git", branch: "main")
```

```swift
import SyncEngineCore
import SyncEngineCoreData

let stack = CoreDataStack()
let pendingStore = CoreDataPendingOperationStore(context: stack.newBackgroundContext())
let syncManager = SyncManager(
    store: pendingStore,
    api: yourRemoteAPIClient,       // conform to RemoteAPIClient
    conflictResolver: HybridConflictResolver(precedenceDeviceID: deviceID) { _ in .nonDestructive }
)
let coordinator = SyncCoordinator(
    syncManager: syncManager,
    changeObserver: CoreDataChangeObserver(context: stack.newBackgroundContext())
)
await coordinator.start()
```

See the [demo app](https://github.com/rajatslakhina/offline-first-sync-engine-demo) for the full wiring, including the network-flakiness simulator and the user-decision conflict UI.

## Source

Built from [Rajat S. Lakhina, "Designing Offline-First Architecture with Swift Concurrency and Core Data Sync"](https://medium.com/@er.rajatlakhina/designing-offline-first-architecture-with-swift-concurrency-and-core-data-sync-46ad5008c7b5) (Medium, Dec 2025). This package is an independent implementation of the architecture described there, not a code excerpt from the article.
