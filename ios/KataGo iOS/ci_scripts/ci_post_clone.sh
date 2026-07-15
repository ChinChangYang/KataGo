#!/bin/sh
set -eu

# Install Metal Toolchain (required for Xcode 26+; not always bundled by default)
METAL_CACHE_DIR="${METAL_CACHE_DIR:-/Users/local/Library/Developer/DVTDownloads/Assets/MetalToolchain}"
METAL_EXPORT_PATH="${METAL_EXPORT_PATH:-/tmp/metalToolchainExport}"
METAL_PATCH_DIR="${METAL_PATCH_DIR:-/tmp/metalToolchainPatched}"

XCODE_BUILD=$(xcodebuild -version | awk '/^Build version/ {print $3}')
echo "Xcode build version: ${XCODE_BUILD}"

# The Metal compiler itself is the only trustworthy signal that the toolchain
# is usable: -importComponent can report "already installed" against a stale
# asset record while every .metal compile still fails (seen when the Xcode
# Cloud image moved to Xcode 26.6/17F113 with only a 17F109 bundle cached).
metal_toolchain_works() {
    PROBE_DIR=$(mktemp -d)
    printf 'kernel void probe() {}\n' > "${PROBE_DIR}/probe.metal"
    if xcrun -sdk macosx metal -c "${PROBE_DIR}/probe.metal" -o "${PROBE_DIR}/probe.air" >/dev/null 2>&1; then
        rm -rf "${PROBE_DIR}"
        return 0
    fi
    rm -rf "${PROBE_DIR}"
    return 1
}

# Import a bundle, tolerating "already installed" (Xcode Cloud sometimes
# pre-imports the toolchain at the system level). metal_toolchain_works is
# the arbiter of success, not the import's exit status.
import_metal_bundle() {
    if IMPORT_OUTPUT=$(xcodebuild -importComponent metalToolchain -importPath "$1" 2>&1); then
        echo "${IMPORT_OUTPUT}"
        return 0
    fi
    echo "${IMPORT_OUTPUT}"
    if echo "${IMPORT_OUTPUT}" | grep -q "already installed"; then
        return 0
    fi
    return 1
}

if metal_toolchain_works; then
    echo "Metal Toolchain already usable; skipping import."
else
    # Locate an already-cached Metal Toolchain bundle (Xcode Cloud pre-caches
    # these). Prefer a bundle whose version matches the running Xcode build;
    # otherwise fall back to whatever's there (patched copy below).
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
        BUNDLE_VERSION=$(basename "${CACHED_BUNDLE}" .exportedBundle | sed 's/MetalToolchain-//')
        echo "Bundle version: ${BUNDLE_VERSION}"
        if [ "${BUNDLE_VERSION}" = "${XCODE_BUILD}" ]; then
            import_metal_bundle "${CACHED_BUNDLE}" || echo "Cached bundle import failed; falling back to a fresh download."
        else
            # Patch a COPY of the bundle. Patching the cached bundle in place
            # makes xcodebuild's asset registry claim the new version is
            # "already installed" while nothing usable was imported.
            echo "Patching a copy of ExportMetadata.plist: ${BUNDLE_VERSION} -> ${XCODE_BUILD}"
            rm -rf "${METAL_PATCH_DIR}"
            mkdir -p "${METAL_PATCH_DIR}"
            PATCHED_BUNDLE="${METAL_PATCH_DIR}/MetalToolchain-${XCODE_BUILD}.exportedBundle"
            if ditto "${CACHED_BUNDLE}" "${PATCHED_BUNDLE}" \
                && sed -i '' "s/${BUNDLE_VERSION}/${XCODE_BUILD}/g" "${PATCHED_BUNDLE}/ExportMetadata.plist"; then
                import_metal_bundle "${PATCHED_BUNDLE}" || echo "Patched bundle import failed; falling back to a fresh download."
            else
                echo "Copy/patch of the cached bundle failed; falling back to a fresh download."
            fi
        fi
    else
        echo "No cached Metal Toolchain bundle found."
    fi

    if ! metal_toolchain_works; then
        echo "Metal Toolchain still unusable; downloading a fresh bundle."
        # Clear cached bundles so -downloadComponent doesn't refuse to redownload.
        rm -rf "${METAL_CACHE_DIR}"/MetalToolchain-*.exportedBundle
        rm -rf "${METAL_EXPORT_PATH}"
        xcodebuild -downloadComponent metalToolchain -exportPath "${METAL_EXPORT_PATH}"

        FRESH_BUNDLE=$(ls -d "${METAL_EXPORT_PATH}"/*.exportedBundle 2>/dev/null | head -n 1 || true)
        if [ -z "${FRESH_BUNDLE}" ] || [ ! -d "${FRESH_BUNDLE}" ]; then
            echo "ERROR: no exportedBundle produced under ${METAL_EXPORT_PATH}"
            exit 1
        fi
        import_metal_bundle "${FRESH_BUNDLE}" || echo "Fresh bundle import failed."

        if ! metal_toolchain_works; then
            echo "ERROR: Metal Toolchain is unusable after import (Xcode ${XCODE_BUILD}); archives would fail at the first .metal file."
            exit 1
        fi
    fi
    echo "Metal Toolchain verified: trivial .metal compile succeeded."
fi

# Download built-in 18b network (Metal backend converts to CoreML on-the-fly)
DEFAULT_MODEL_GZ="default_model.bin.gz"
DEFAULT_MODEL_URL="https://github.com/ChinChangYang/KataGo/releases/download/v1.15.1-coreml2/kata1-b18c384nbt-s9996604416-d4316597426.bin.gz"
DEFAULT_MODEL_RES="../Resources/default_model.bin.gz"

rm -f "$DEFAULT_MODEL_GZ"
curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_URL"
cp -f "$DEFAULT_MODEL_GZ" "$DEFAULT_MODEL_RES"

# Download human SL model
HUMAN_MODEL_GZ="b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_URL="https://github.com/lightvector/KataGo/releases/download/v1.15.0/b18c384nbt-humanv0.bin.gz"
HUMAN_MODEL_RES="../Resources/b18c384nbt-humanv0.bin.gz"

curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_URL"
cp -f "$HUMAN_MODEL_GZ" "$HUMAN_MODEL_RES"

# Opening books are NOT bundled. Each board size's compact .kbook.gz is
# downloaded on demand in-app (see OpeningBook.swift / OpeningBookPickerView),
# so there is no book to fetch here.
