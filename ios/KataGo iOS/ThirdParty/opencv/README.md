# Vendored OpenCV 5.0.0 (trimmed)

A local SwiftPM package that compiles a trimmed **OpenCV 5.0.0** from source as a
single static C++ library target, for macOS, iOS/iOS Simulator, and
visionOS/visionOS Simulator. It is the OpenCV dependency of the C++ Go-board
photo-recognition pipeline (`CGobanRecog`), whose Python reference runs
`opencv-python` 5.0.0 — the vendored version must stay **exactly 5.0.0** for
behavioral parity (RANSAC/LMEDS sampling, `HoughLinesP`, `INTER_AREA` resize, ...).

- Upstream source: <https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz>
- License: Apache-2.0 (see `LICENSE`, preserved verbatim from the tarball)
- Sources are pristine upstream copies — **no patches** (hence no `PATCHES.md`)

## What is vendored

Whole modules only (intra-module trimming breaks OpenCV):

| Directory | Upstream origin | Why |
|---|---|---|
| `Sources/OpenCV/core/` | `modules/core/src/` | Mat, arithmetic, RNG, SVD, perspectiveTransform, exceptions |
| `Sources/OpenCV/imgproc/` | `modules/imgproc/src/` | cvtColor, filters, morphology, Canny, HoughLinesP, resize, warp, findContours, distanceTransform |
| `Sources/OpenCV/geometry/` | `modules/geometry/src/` | `findHomography` / `estimateAffine2D` live **here** in 5.0 (the 4.x calib3d was reorganized); also convexHull/contourArea/arcLength/approxPolyDP moved here from imgproc |
| `Sources/OpenCV/flann/` | `modules/flann/src/` | hard link-time dependency of geometry: `fundam.cpp` unconditionally references `usac::findHomography`, and `usac/utils.cpp` uses `cv::flann::Index` (miniflann) |
| `Sources/OpenCV/include/opencv2/` | the four modules' `include/opencv2/` trees + top-level `include/opencv2/opencv.hpp` | public headers (copies, not symlinks) |

Dependency order: `core ← flann ← geometry ← imgproc`. The set is closed — no
other module is referenced (verified by grepping all four src/include trees for
cross-module `opencv2/...` includes). imgcodecs, highgui, dnn, video(io),
features, calib, stereo, ptcloud, etc. are excluded entirely.

Note: `cv::findHomography` with method `0`/`RANSAC`/`LMEDS` executes the legacy
registrators in `geometry/src/ptsetreg.cpp` (USAC is used only for the `USAC_*`
method constants), and `cv::estimateAffine2D(..., LMEDS)` likewise — but the
USAC sources must still compile for link-time completeness.

## Build configuration

Chosen to match the algorithmic behavior of the official `opencv-python`
5.0.0 macOS arm64 wheel (see caveats below):

- No IPP, no OpenCL, no ITT, no LAPACK, no OpenMP/TBB (parallel_for uses
  GCD/pthreads), no Eigen
- C++ exceptions and RTTI on; `gnu++17`
- zlib from the Apple SDK (`-lz`), not vendored
- CPU baseline: NEON on arm64; plain baseline on x86_64 (SSE2 universal
  intrinsics still auto-enable from `__SSE2__`). **CPU dispatch off everywhere**
  — no per-ISA translation units; the merged `generated/cv_cpu_config.h`
  selects per-arch via `#if defined(__aarch64__)`
- Custom ARM HALs (carotene, KleidiCV) **off** — the wheel has them on, but
  KleidiCV is downloaded at configure time and both are large vendoring webs;
  if a numerical mismatch vs Python is ever traced to a HAL-accelerated
  primitive, revisit this
- The wheel also enables LAPACK (Accelerate) and a wider NEON baseline
  (FP16/DOTPROD); this package intentionally uses OpenCV's built-in SVD path
  and plain NEON per the port's build spec

## Generated headers (`Sources/OpenCV/generated/`)

CMake-generated, then lightly sanitized (absolute build paths replaced —
`CV_CPU_SIMD_FILENAME` basenames in `*.simd_declarations.hpp`, neutral values
in `opencv_data_config.hpp`, and the two-arch merge of `cv_cpu_config.h`):

- `cvconfig.h`, `custom_hal.hpp`, `opencv_data_config.hpp`, `version_string.inc`
- `cv_cpu_config.h` (merged arm64/x86_64)
- `include/opencv2/opencv_modules.hpp` (public)
- `generated/{core,imgproc}/**.simd_declarations.hpp` — baseline-only dispatch
  declarations
- `generated/{core,imgproc,geometry}/opencl_kernels_*.hpp` — produced by
  `cmake/cl2cpp.cmake`; entirely `#ifdef HAVE_OPENCL`-guarded, so no kernel
  `.cpp` is compiled
- `generated/imgproc/builtin_font_{sans,italic}.h` — produced by
  `ocv_blob2hdr()` from the in-tree `modules/imgproc/fonts/Rubik*.ttf.gz`
  (WITH_UNIFONT=OFF: the CJK font is a configure-time download; `putText` with
  non-Latin text would fall back, which the app never does)

## Regeneration steps

```sh
# 1. Fetch and unpack the exact upstream source
curl -L -o opencv-5.0.0.tar.gz \
  https://github.com/opencv/opencv/archive/refs/tags/5.0.0.tar.gz
tar xzf opencv-5.0.0.tar.gz

# 2. Configure twice (no build needed) to produce the generated headers
#    (cmake 4.2.3 was used originally)
cmake -S opencv-5.0.0 -B build-arm64 \
  -DBUILD_LIST=core,imgproc,geometry,flann \
  -DCPU_BASELINE=NEON -DCPU_DISPATCH= \
  -DWITH_IPP=OFF -DWITH_OPENCL=OFF -DWITH_ITT=OFF -DWITH_LAPACK=OFF -DWITH_EIGEN=OFF \
  -DWITH_OPENMP=OFF -DWITH_TBB=OFF -DWITH_PROTOBUF=OFF \
  -DWITH_CAROTENE=OFF -DWITH_KLEIDICV=OFF -DWITH_UNIFONT=OFF \
  -DBUILD_ZLIB=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_opencv_apps=OFF \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_opencv_python3=OFF -DBUILD_JAVA=OFF -DBUILD_OBJC=OFF

cmake -S opencv-5.0.0 -B build-x86_64 -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCPU_BASELINE=SSE4_2 <same remaining flags as above>
# (SSE4_2 fails the cross-arch feature test and degrades to a plain baseline,
#  which is what we want: no -msse4.2 is ever passed by SwiftPM)

# 3. OpenCL kernel stub headers (normally generated at build time)
for m in core imgproc geometry; do
  cmake -DMODULE_NAME=$m -DCL_DIR=$PWD/opencv-5.0.0/modules/$m/src/opencl \
        -DOUTPUT=$PWD/clgen/opencl_kernels_$m.cpp \
        -P opencv-5.0.0/cmake/cl2cpp.cmake   # vendor only the .hpp
done

# 4. Copy into the package
#    modules/{core,imgproc,geometry,flann}/src -> Sources/OpenCV/<module>
#    modules/*/include/opencv2 + include/opencv2/opencv.hpp -> Sources/OpenCV/include/opencv2
#    build-arm64/{cvconfig.h,custom_hal.hpp} -> generated/
#    build-arm64/modules/core/version_string.inc -> generated/
#    build-arm64/modules/{core,imgproc}/*.simd_declarations.hpp -> generated/<module>/
#    build-arm64/modules/imgproc/builtin_font_{sans,italic}.h -> generated/imgproc/
#    build-arm64/opencv2/opencv_modules.hpp -> include/opencv2/
#    clgen/opencl_kernels_*.hpp -> generated/<module>/
#    merge build-{arm64,x86_64}/cv_cpu_config.h -> generated/cv_cpu_config.h
#      (#if defined(__aarch64__) selects the arm64 half)
#    rewrite CV_CPU_SIMD_FILENAME absolute paths to basenames:
#      sed -i '' 's|#define CV_CPU_SIMD_FILENAME ".*/\([^/]*\.simd\.hpp\)"|#define CV_CPU_SIMD_FILENAME "\1"|'
#    sanitize opencv_data_config.hpp (drop build-machine paths)
```

`Package.swift` excludes the OpenCL kernel dirs, CUDA sources, the empty
`main.cpp` init files, and the old-style per-ISA files
(`*.avx*.cpp`, `*.sse4_1.cpp`, `*.lasx.cpp` — their call sites are gated by
`CV_TRY_*` macros that are 0 with dispatch off).

## Verification

From this directory:

```sh
swift build     # macOS native
swift test      # OpenCVSmokeTests: cvtColor/BLACKHAT/warp/findHomography(RANSAC)/estimateAffine2D
xcodebuild -scheme OpenCV -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -scheme OpenCV -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
xcodebuild -scheme OpenCV -destination 'platform=macOS' build
```
