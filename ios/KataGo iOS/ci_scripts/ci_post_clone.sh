#!/bin/sh
set -eu

# Install Metal Toolchain (required for Xcode 26+; not always bundled by default)
METAL_CACHE_DIR="/Users/local/Library/Developer/DVTDownloads/Assets/MetalToolchain"
METAL_EXPORT_PATH="/tmp/metalToolchainExport"

XCODE_BUILD=$(xcodebuild -version | awk '/^Build version/ {print $3}')
echo "Xcode build version: ${XCODE_BUILD}"

# Locate an already-cached Metal Toolchain bundle (Xcode Cloud pre-caches these).
# If `xcodebuild -downloadComponent` finds one it refuses to redownload, but the
# bundle still needs `-importComponent` to be usable at compile time. Prefer a
# bundle whose version matches the running Xcode build; otherwise fall back to
# whatever's there (sed step below will reconcile the version).
CACHED_BUNDLE=""
if [ -d "${METAL_CACHE_DIR}" ]; then
    for bundle in "${METAL_CACHE_DIR}"/MetalToolchain-*.exportedBundle; do
        [ -d "${bundle}" ] || continue
        case "${bundle}" in
            *"MetalToolchain-${XCODE_BUILD}.exportedBundle")
                CACHED_BUNDLE="${bundle}"
                break
                ;;
        esac
        [ -z "${CACHED_BUNDLE}" ] && CACHED_BUNDLE="${bundle}"
    done
fi

if [ -n "${CACHED_BUNDLE}" ]; then
    echo "Using cached Metal Toolchain bundle: ${CACHED_BUNDLE}"
    BUNDLE_PATH="${CACHED_BUNDLE}"
else
    echo "No cached Metal Toolchain found; downloading."
    rm -rf "${METAL_EXPORT_PATH}"
    xcodebuild -downloadComponent metalToolchain -exportPath "${METAL_EXPORT_PATH}"

    BUNDLE_PATH=$(ls -d "${METAL_EXPORT_PATH}"/*.exportedBundle 2>/dev/null | head -n 1 || true)
    if [ -z "${BUNDLE_PATH}" ] || [ ! -d "${BUNDLE_PATH}" ]; then
        echo "ERROR: no exportedBundle produced under ${METAL_EXPORT_PATH}"
        exit 1
    fi
fi

# Patch ExportMetadata.plist so its version matches the running Xcode build
# (no-op when the bundle version already matches, which is typical for the
# pre-cached toolchain).
BUNDLE_VERSION=$(basename "${BUNDLE_PATH}" .exportedBundle | sed 's/MetalToolchain-//')
echo "Bundle version: ${BUNDLE_VERSION}"
if [ "${BUNDLE_VERSION}" != "${XCODE_BUILD}" ]; then
    echo "Patching ExportMetadata.plist: ${BUNDLE_VERSION} -> ${XCODE_BUILD}"
    sed -i '' "s/${BUNDLE_VERSION}/${XCODE_BUILD}/g" "${BUNDLE_PATH}/ExportMetadata.plist"
fi

# Tolerate "already installed" — Xcode Cloud sometimes pre-imports the toolchain
# at the system level, and `-importComponent` then errors out. Treat that as success.
if ! IMPORT_OUTPUT=$(xcodebuild -importComponent metalToolchain -importPath "${BUNDLE_PATH}" 2>&1); then
    echo "${IMPORT_OUTPUT}"
    if echo "${IMPORT_OUTPUT}" | grep -q "already installed"; then
        echo "Metal Toolchain already installed; continuing."
    else
        exit 1
    fi
else
    echo "${IMPORT_OUTPUT}"
fi

# Download built-in 18b network (Metal backend converts to CoreML on-the-fly)
DEFAULT_MODEL_GZ="default_model.bin.gz"
DEFAULT_MODEL_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz"
DEFAULT_MODEL_RES="../Resources/default_model.bin.gz"

rm -f "$DEFAULT_MODEL_GZ"
curl -L --retry 5 --retry-delay 3 -o "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_URL"
cp -f "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_RES"

# Download human SL model
HUMAN_MODEL_GZ="b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_URL="https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_RES="../Resources/b18c384nbt-humanv0.bin.gz"

curl -L --retry 5 --retry-delay 3 -o "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_URL"
cp -f "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_RES"

# Download 9x9 opening book.
# NOTE: unlike the .bin.gz networks (app-target ../Resources/), the book is a
# KataGoUICore SwiftPM package resource loaded via Bundle.module (see refactor
# 405f34c1). It MUST land in the package's Resources dir so `.process("Resources")`
# bundles it into KataGoUICore_KataGoUICore.bundle; otherwise BookLookupTests
# .loadsRealBundledBook() fails in CI (Bundle.module can't resolve it).
BOOK_GZ="book9x9jp-20260226.kbook.gz"
BOOK_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.16.4-coreml1/book9x9jp-20260226.kbook.gz"
BOOK_RES="../KataGoUICore/Sources/KataGoUICore/Resources/book9x9jp-20260226.kbook.gz"

curl -L --retry 5 --retry-delay 3 -o "$BOOK_GZ" "$BOOK_URL"
cp -f "$BOOK_GZ" "$BOOK_RES"
