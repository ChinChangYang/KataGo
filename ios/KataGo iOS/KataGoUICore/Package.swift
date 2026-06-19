// swift-tools-version: 6.2
import PackageDescription

// Header search paths the bridge's C++ sources (KataGoCpp/SgfCpp/RulesCpp)
// need to compile against the KataGo engine headers. These mirror the
// `katago` Xcode framework target's HEADER_SEARCH_PATHS +
// SYSTEM_HEADER_SEARCH_PATHS.
//
// IMPORTANT — these MUST be relative to the directory the compiler runs in,
// NOT the package/target source dir. When Xcode/XCBuild compiles a SwiftPM
// C++ target the clang working directory is the directory CONTAINING the
// .xcodeproj (i.e. `ios/KataGo iOS/KataGo Anytime.xcodeproj/`), so the repo's
// cpp/ tree is three levels up (`../../../cpp`). (SwiftPM's `.headerSearchPath`
// can't be used here because it rejects any path outside the package root.)
//
// The bridge only #includes "main.h" and "sgf.h"; everything else is pulled
// in transitively by the engine headers via their own relative includes, so
// it only needs the roots on the search path. The C++ target does NOT
// recompile the engine — symbols resolve at app link time against the katago
// framework.
let engineHeaderFlags: [String] = [
    "-I", "../../../cpp",
    "-I", "../../../cpp/dataio",
    "-I", "../../../cpp/external/tclap-1.2.5/include",
    "-I", "../../../cpp/external",
    // MLX (USE_MLX_BACKEND) headers, pulled in transitively via nninterface.h.
    // ThirdParty/ sits directly under `ios/KataGo iOS/`, one level up from the
    // .xcodeproj working directory.
    "-I", "../ThirdParty/mlx-swift/Source/Cmlx/mlx",
    "-I", "../ThirdParty/mlx-swift/Source/Cmlx/mlx-c",
    // System header search paths (the engine target marks these as system).
    "-I", "../../../cpp/external/filesystem-1.5.8/include",
    "-I", "../../../cpp/external/katagocoreml/include",
    "-I", "../../../cpp/external/katagocoreml/src",
    "-I", "../../../cpp/external/katagocoreml/generated",
    "-I", "../../../cpp/external/katagocoreml/vendor/mlmodel/format",
    "-I", "../../../cpp/external/katagocoreml/vendor/mlmodel/src",
    "-I", "../../../cpp/external/katagocoreml/vendor/modelpackage/src",
    "-I", "../../../cpp/external/katagocoreml/vendor/deps/FP16/include",
    "-I", "../../../cpp/external/nlohmann_json",
    "-I", "../../../cpp/external/protobuf-34.1/src",
    "-I", "../../../cpp/external/protobuf-34.1/third_party/utf8_range",
    "-I", "../../../cpp/external/abseil-cpp-20260107.1",
]

let package = Package(
    name: "KataGoUICore",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        // Static so consumers link the package's object code into THEIR final
        // binary. That defers CKataGoBridge's KataGo-engine symbol references
        // (MainCmds::gtp, Sgf::parse, katagocoreml_*, …) to the consumer's
        // link: the app resolves them against the embedded `katago` /
        // `KataGoSwift` Xcode frameworks, and the unit-test bundle resolves
        // them against its host app via `-bundle_loader` (BUNDLE_LOADER is set
        // on the test target). A dynamic product would instead need
        // `-undefined dynamic_lookup`, which is deprecated on the iOS/visionOS
        // simulators and emits a build warning. The test target therefore does
        // NOT also link this product (only the app does) to avoid SwiftPM's
        // static-duplication diagnostic.
        .library(name: "KataGoUICore", type: .static, targets: ["KataGoUICore"]),
        // Dependency-light Core ML cache, split out so the headless
        // katago-engine helper can link it without the UI core (SwiftUI,
        // SwiftData, FoundationModels, …). Foundation/OSLog/CryptoKit only.
        .library(name: "CoreMLCacheKit", type: .static, targets: ["CoreMLCacheKit"]),
    ],
    targets: [
        // C++ bridge between Swift and the KataGo engine. Folded in from the
        // former KataGoInterface Xcode framework so the Swift wrappers'
        // dependency on these C++ symbols is an INTRA-package edge that
        // SwiftPM orders, fixing the cold-build module-emit race that broke
        // an Xcode-framework -> SwiftPM-package dependency.
        .target(
            name: "CKataGoBridge",
            cxxSettings: [
                // Engine defines (must match the katago framework's
                // GCC_PREPROCESSOR_DEFINITIONS so the engine headers expand
                // identically). OS_IS_IOS is set unconditionally on all three
                // platforms by the app/engine targets (no per-SDK variant),
                // so it is replicated unconditionally here too.
                .define("USE_MLX_BACKEND"),
                .define("NO_LIBZIP"),
                .define("NO_GIT_REVISION"),
                .define("OS_IS_IOS"),
                .define("COMPILE_MAX_BOARD_LEN", to: "37"),
                .define("DEBUG", to: "1", .when(configuration: .debug)),
                .unsafeFlags(engineHeaderFlags),
            ]
        ),
        // Pure-Swift, dependency-light Core ML cache (no CKataGoBridge, no Cxx
        // interop). Its `@_silgen_name("katagocoreml_converter_version")` symbol
        // resolves at the consumer's link against katago.framework, mirroring
        // CKataGoBridge's deferred-link pattern.
        .target(
            name: "CoreMLCacheKit"
        ),
        .target(
            name: "KataGoUICore",
            dependencies: ["CKataGoBridge", "CoreMLCacheKit"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                // The bridge exposes C++ headers (e.g. KataGoCpp.hpp includes
                // <string>), so importing CKataGoBridge requires Swift/C++
                // interop on this target, matching the app target.
                .interoperabilityMode(.Cxx)
            ]
        )
    ]
)
