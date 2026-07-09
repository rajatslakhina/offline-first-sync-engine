import XCTest
@testable import SyncEngineCore

final class ConflictResolutionTests: XCTestCase {
    func test_lastWriteWins_prefersNewerLocalTimestamp() async {
        let resolver = LastWriteWinsResolver()
        let now = Date()
        let local = SyncOperation(entityID: "x", kind: .update, payload: [:], localTimestamp: now, deviceID: "a")
        let remote = RemoteSnapshot(entityID: "x", remoteTimestamp: now.addingTimeInterval(-10), deviceID: "b", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .acceptLocal)
    }

    func test_lastWriteWins_prefersNewerRemoteTimestamp() async {
        let resolver = LastWriteWinsResolver()
        let now = Date()
        let local = SyncOperation(entityID: "x", kind: .update, payload: [:], localTimestamp: now.addingTimeInterval(-10), deviceID: "a")
        let remote = RemoteSnapshot(entityID: "x", remoteTimestamp: now, deviceID: "b", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .acceptRemote)
    }

    func test_userIntervention_alwaysRequiresDecision_regardlessOfTimestamps() async {
        let resolver = UserInterventionResolver()
        let now = Date()
        // Local is unambiguously newer — a last-write-wins resolver would
        // accept it outright. UserInterventionResolver must not care.
        let local = SyncOperation(entityID: "x", kind: .delete, payload: [:], localTimestamp: now, deviceID: "a")
        let remote = RemoteSnapshot(entityID: "x", remoteTimestamp: now.addingTimeInterval(-100), deviceID: "b", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .requiresUserDecision)
    }

    func test_devicePrecedence_breaksNearSimultaneousTiesByDeviceID() async {
        let resolver = DeviceTimestampPrecedenceResolver(precedenceDeviceID: "primary-device")
        let now = Date()
        let local = SyncOperation(entityID: "x", kind: .update, payload: [:], localTimestamp: now, deviceID: "primary-device")
        // Within the same second — a genuine near-simultaneous edit.
        let remote = RemoteSnapshot(entityID: "x", remoteTimestamp: now.addingTimeInterval(0.3), deviceID: "secondary-device", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .acceptLocal, "the precedence device should win a near-simultaneous tie even though it's not strictly newer")
    }

    func test_devicePrecedence_fallsBackToTimestampWhenNotATie() async {
        let resolver = DeviceTimestampPrecedenceResolver(precedenceDeviceID: "primary-device")
        let now = Date()
        // Not a tie: remote is 10 seconds newer, so precedence shouldn't apply.
        let local = SyncOperation(entityID: "x", kind: .update, payload: [:], localTimestamp: now, deviceID: "primary-device")
        let remote = RemoteSnapshot(entityID: "x", remoteTimestamp: now.addingTimeInterval(10), deviceID: "secondary-device", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .acceptRemote)
    }

    func test_hybridResolver_routesDestructiveFieldsToUserIntervention() async {
        let resolver = HybridConflictResolver(precedenceDeviceID: "primary-device") { _ in .destructive }
        let now = Date()
        let local = SyncOperation(entityID: "balance", kind: .update, payload: [:], localTimestamp: now, deviceID: "a")
        let remote = RemoteSnapshot(entityID: "balance", remoteTimestamp: now.addingTimeInterval(-100), deviceID: "b", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .requiresUserDecision)
    }

    func test_hybridResolver_routesNonDestructiveSameDeviceFieldsToLastWriteWins() async {
        let resolver = HybridConflictResolver(precedenceDeviceID: "primary-device") { _ in .nonDestructive }
        let now = Date()
        let local = SyncOperation(entityID: "note", kind: .update, payload: [:], localTimestamp: now, deviceID: "same-device")
        let remote = RemoteSnapshot(entityID: "note", remoteTimestamp: now.addingTimeInterval(-100), deviceID: "same-device", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .acceptLocal)
    }

    func test_hybridResolver_alwaysRoutesDeletesToUserIntervention_evenIfClassifiedNonDestructive() async {
        // A classifier that (mis)labels everything non-destructive should
        // still never auto-resolve a delete — deletes are irreversible by
        // definition, so the resolver overrides the classifier here.
        let resolver = HybridConflictResolver(precedenceDeviceID: "primary-device") { _ in .nonDestructive }
        let now = Date()
        let local = SyncOperation(entityID: "note", kind: .delete, payload: [:], localTimestamp: now, deviceID: "a")
        let remote = RemoteSnapshot(entityID: "note", remoteTimestamp: now.addingTimeInterval(-100), deviceID: "b", payload: [:])

        let resolution = await resolver.resolve(local: local, remote: remote)

        XCTAssertEqual(resolution, .requiresUserDecision)
    }
}
