// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OfflineSyncEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        // Pure Swift sync engine: actor coordinator, conflict resolution, retry policy.
        // Has zero platform dependencies, so it builds and tests on Linux CI too.
        .library(name: "SyncEngineCore", targets: ["SyncEngineCore"]),
        // Core Data-backed persistence + change observation. Apple platforms only.
        .library(name: "SyncEngineCoreData", targets: ["SyncEngineCoreData"])
    ],
    targets: [
        .target(
            name: "SyncEngineCore",
            path: "Sources/SyncEngineCore"
        ),
        .target(
            name: "SyncEngineCoreData",
            dependencies: ["SyncEngineCore"],
            path: "Sources/SyncEngineCoreData",
            resources: [.process("Resources/OfflineSyncModel.xcdatamodeld")]
        ),
        .testTarget(
            name: "SyncEngineCoreTests",
            dependencies: ["SyncEngineCore"],
            path: "Tests/SyncEngineCoreTests"
        )
    ]
)
