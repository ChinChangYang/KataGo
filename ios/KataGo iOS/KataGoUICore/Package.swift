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
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26), .tvOS(.v26), .watchOS(.v26)],
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
        // Bridge-free SwiftData models + shared container + widget-facing
        // helpers. The widget extension links ONLY this product, so it must
        // never depend on CKataGoBridge / MLX. SwiftData + SwiftUI + AppIntents
        // only.
        .library(name: "KataGoGameStore", type: .static, targets: ["KataGoGameStore"]),
        // Board-photo recognition (Python GobanRecog → C++/OpenCV port). Linked
        // ONLY by the iOS/visionOS and macOS app targets. Kept in a SEPARATE
        // product from KataGoUICore so that OpenCV (heavy, and absent on
        // tvOS/watchOS) never enters those platforms' link graphs.
        .library(name: "GobanRecogKit", type: .static, targets: ["GobanRecogKit"]),
    ],
    dependencies: [
        // Vendored OpenCV 5.0.0 (local SwiftPM package). Consumed ONLY by the
        // CGobanRecog target below, which in turn is reachable ONLY through the
        // GobanRecogKit product — never through the KataGoUICore product. This
        // keeps OpenCV out of the tvOS/watchOS/widget link graphs (they link
        // KataGoUICore / KataGoGameStore, not GobanRecogKit).
        .package(path: "../ThirdParty/opencv"),
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
        // Pure-Swift, bridge-free SwiftData layer. No Cxx interop.
        .target(
            name: "KataGoGameStore"
        ),
        .target(
            name: "KataGoUICore",
            dependencies: ["CKataGoBridge", "CoreMLCacheKit", "KataGoGameStore"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                // The bridge exposes C++ headers (e.g. KataGoCpp.hpp includes
                // <string>), so importing CKataGoBridge requires Swift/C++
                // interop on this target, matching the app target.
                .interoperabilityMode(.Cxx)
            ]
        ),
        // C++ home of the GobanRecog board-recognition port. Depends ONLY on
        // the vendored OpenCV product — NO engine headers. Include-path
        // unsafeFlags remain BANNED here (unlike CKataGoBridge); the sole
        // unsafeFlag is `-ffp-contract=off`, a deliberate, documented parity
        // requirement — numpy never fuses multiply-adds into an FMA, so the
        // float32 threshold/score arithmetic must not contract either. Applying
        // it target-wide (rather than only via the per-file `#pragma STDC
        // FP_CONTRACT OFF` in gr_parity.cpp/gr_grid.cpp, which are kept as
        // belt-and-suspenders) guarantees every current and future port .cpp
        // inherits it. The public seam (include/GobanRecogCpp.hpp +
        // module.modulemap) exposes plain C++ std types only (no cv:: types) so
        // GobanRecogKit can import it over Swift/C++ interop. Modelled on
        // CKataGoBridge, minus the engine wiring.
        .target(
            name: "CGobanRecog",
            dependencies: [
                .product(name: "OpenCV", package: "opencv"),
            ],
            cxxSettings: [
                .unsafeFlags(["-ffp-contract=off"]),
            ]
        ),
        // Swift face of the recognizer. Imports the C++ CGobanRecog module, so
        // it needs Swift/C++ interop (same house pattern as KataGoUICore). Its
        // KataGoUICore dependency lets later tasks bridge results into the app's
        // shared models without OpenCV leaking into the KataGoUICore product.
        .target(
            name: "GobanRecogKit",
            dependencies: ["CGobanRecog", "KataGoUICore"],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
        // Micro-parity harness CLI for the CGobanRecog port (Python <-> C++
        // stage comparison, paired with the GobanRecog repo's tools/). NOT in
        // any product, so app schemes never build it; run on macOS via
        // `swift run gobanrecog-dev`. Depends ONLY on CGobanRecog.
        .executableTarget(
            name: "gobanrecog-dev",
            dependencies: ["CGobanRecog"]
        ),
        // Command-line recognizer (run.py + board_to_sgf end-to-end) that the
        // Task-10 600-image eval drives. Like gobanrecog-dev it is NOT in any
        // product/app scheme; run on macOS via `swift run gobanrecog-cli`.
        // Takes a RAW BGR dump (imgcodecs is not vendored) + width/height and
        // reaches the pipeline through CGobanRecog's cv-free bridge; never
        // touches cv:: directly. Depends ONLY on CGobanRecog.
        .executableTarget(
            name: "gobanrecog-cli",
            dependencies: ["CGobanRecog"]
        ),
        // Native tests for the CGobanRecog port's numpy-parity helpers, types,
        // and constants. Depends ONLY on CGobanRecog (which depends only on
        // OpenCV) so `swift test --filter GobanRecogNativeTests` builds and runs
        // standalone on macOS without dragging in CKataGoBridge's engine-symbol
        // link. Uses Swift/C++ interop to call the cv-free test bridge
        // (GobanRecogTestBridge.hpp). Ground-truth values come from numpy 2.5.1.
        .testTarget(
            name: "GobanRecogNativeTests",
            dependencies: ["CGobanRecog"],
            // img0811.bgr.raw (602x626x3 BGR, cv2.imread(...).tofile) drives the
            // end-to-end recognize_image smoke test (status ok, size 19); the
            // SGF/rows path is proven by the Task-9 fixture sanity + gr_sgf unit
            // tests. Bundled via Bundle.module.
            resources: [
                .copy("Resources")
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        )
    ],
    // C++17 for the whole package: CGobanRecog's later port tasks adopt
    // std::optional (conventions rules 4/5). This also raises CKataGoBridge to
    // gnu++17 (the xcodeproj already compiles the same bridge code at
    // gnu++17/20). Matches the vendored ThirdParty/opencv package's declaration.
    cxxLanguageStandard: .gnucxx17
)
