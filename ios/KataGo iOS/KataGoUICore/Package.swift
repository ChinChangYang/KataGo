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
            name: "KataGoUICore"
        )
    ]
)
