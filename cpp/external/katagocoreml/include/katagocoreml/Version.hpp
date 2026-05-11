#pragma once

namespace katagocoreml {
constexpr const char* VERSION = "1.1.0";
constexpr int VERSION_MAJOR = 1;
constexpr int VERSION_MINOR = 1;
constexpr int VERSION_PATCH = 0;

// Cache-key-stable converter version. Bumping `VERSION` is the documented
// way to invalidate every user's Core ML cache when the converter starts
// producing different .mlpackage bytes for the same logical inputs.
//
// CONTRACT: Spec docs/superpowers/specs/2026-05-09-coreml-cache-design.md
// puts the return value of `current()` into the cache-key digest. Any
// time the converter's *output* changes, bump VERSION (semver: minor for
// behavior changes that produce new .mlpackage bytes; patch for cosmetic
// fixes that don't).
struct ConverterVersion {
    static constexpr const char* current() { return VERSION; }
};
}  // namespace katagocoreml
