// swift-tools-version: 6.0
// Vendored OpenCV 5.0.0 (core, imgproc, geometry, flann) as a single static
// C++ library target. See README.md for what is vendored, why, and how to
// regenerate the config headers.

import PackageDescription

let package = Package(
    name: "OpenCV",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0"),
        .visionOS("26.0"),
    ],
    products: [
        .library(name: "OpenCV", type: .static, targets: ["OpenCV"])
    ],
    targets: [
        .target(
            name: "OpenCV",
            path: "Sources/OpenCV",
            exclude: [
                // "Library initialization file"s whose only content is
                // IPP_INITIALIZER_AUTO, which expands to nothing with IPP off.
                // A file named main.cpp would also make SwiftPM misclassify
                // the target as an executable.
                "imgproc/main.cpp",
                "geometry/main.cpp",

                // CUDA device sources (no CUDA on Apple platforms).
                "core/cuda",

                // OpenCL kernels (.cl) and the OpenCL runtime loader/generator.
                // HAVE_OPENCL is off; the generated opencl_kernels_*.hpp stubs
                // under generated/ satisfy the unconditional includes.
                "core/opencl",
                "imgproc/opencl",
                "geometry/opencl",

                // Old-style per-ISA translation units that require -mavx2 /
                // -msse4.1 / LoongArch flags. CPU dispatch is off, so their
                // call sites (guarded by CV_TRY_AVX2 / CV_TRY_SSE4_1 / ...)
                // compile to nothing and the symbols are never referenced.
                "imgproc/corner.avx.cpp",
                "imgproc/imgwarp.avx2.cpp",
                "imgproc/imgwarp.sse4_1.cpp",
                "imgproc/imgwarp.lasx.cpp",
                "imgproc/resize.avx2.cpp",
                "imgproc/resize.sse4_1.cpp",
                "imgproc/resize.lasx.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                // CMake-generated configuration headers (cvconfig.h,
                // cv_cpu_config.h, custom_hal.hpp, version_string.inc,
                // opencv_data_config.hpp) and per-module generated headers
                // (*.simd_declarations.hpp, opencl_kernels_*.hpp, fonts).
                .headerSearchPath("generated"),
                .headerSearchPath("generated/core"),
                .headerSearchPath("generated/imgproc"),
                .headerSearchPath("generated/geometry"),

                // Definitions used by the upstream CMake build
                // (from compile_commands.json of the reference configure).
                .define("__OPENCV_BUILD", to: "1"),
                .define("_USE_MATH_DEFINES"),
                .define("__STDC_CONSTANT_MACROS"),
                .define("__STDC_FORMAT_MACROS"),
                .define("__STDC_LIMIT_MACROS"),
                .define("OPENCV_ALLOCATOR_STATS_COUNTER_TYPE", to: "int"),
            ],
            linkerSettings: [
                // imgproc/drawing_text.cpp inflates the built-in fonts with zlib.
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "OpenCVSmokeTests",
            dependencies: ["OpenCV"],
            path: "Tests/OpenCVSmokeTests",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("XCTest"),
            ]
        ),
    ],
    cxxLanguageStandard: .gnucxx17
)
