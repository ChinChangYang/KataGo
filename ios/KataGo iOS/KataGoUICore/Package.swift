// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KataGoUICore",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "KataGoUICore", targets: ["KataGoUICore"])
    ],
    targets: [
        .target(
            name: "KataGoUICore",
            swiftSettings: [
                // KataGoInterface exposes C++ headers (e.g. KataGoCpp.hpp includes
                // <string>), so importing it requires Swift/C++ interop on this target,
                // matching the app target.
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
