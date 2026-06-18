// swift-tools-version: 6.2
import PackageDescription

// Pure-Foundation package: spawns and talks to a KataGo engine SUBPROCESS over
// stdin/stdout pipes (macOS). Deliberately has NO dependency on the C++ engine
// or CKataGoBridge, so `swift test` builds and runs on macOS with no engine
// symbols to link. The Mac app target depends on this package; iOS/visionOS
// keep the in-process C++ bridge (they cannot spawn subprocesses).
let package = Package(
    name: "KataGoEngineIPC",
    platforms: [.macOS(.v13), .iOS(.v16), .visionOS(.v1)],
    products: [
        .library(name: "KataGoEngineIPC", targets: ["KataGoEngineIPC"]),
    ],
    targets: [
        .target(name: "KataGoEngineIPC"),
        .testTarget(name: "KataGoEngineIPCTests", dependencies: ["KataGoEngineIPC"]),
    ]
)
