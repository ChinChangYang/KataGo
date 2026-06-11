# MLX License Attribution — Design Spec

**Date:** 2026-06-12
**Status:** Approved direction (A1 + B1 + C1), pending spec review

**Goal:** Make KataGo Anytime compliant with the attribution obligations of its
permissively-licensed third-party dependencies before App Store / TestFlight
release, by adding an in-app "Open-Source Licenses" screen and updating the
repository's `/LICENSE`.

**Architecture:** A new SwiftUI list→detail screen, reachable from the existing
*Configurations* screen, renders the verbatim license text of every third-party
component compiled or linked into the shipped iOS binary. License texts are
embedded as Swift string constants (no app-resource bundling). The repo-root
`/LICENSE` is updated to enumerate the MLX-family components for source-side
attribution.

**Tech Stack:** SwiftUI, XCUITest. No C++, no SwiftData, no new SwiftPM deps.

---

## Background: Is MLX a release blocker?

**No.** The App Store rejects the **GPL family** (GPL/LGPL/AGPL) because its
"no additional restrictions" clause conflicts with Apple's standard EULA/DRM.
MLX and its entire transitive tree are permissive (MIT / Apache-2.0 / BSD-3),
fully compatible with App Store and TestFlight. (Apple authored MLX.)

The **one real obligation** is attribution: MIT, Apache-2.0, and BSD-3 all
require reproducing the copyright + permission notice in distributions,
**including binary distributions**. The customary way to satisfy this for a
shipped iOS app is an accessible in-app license list. Today the app has **no
acknowledgments screen**, and `/LICENSE` does not yet mention the MLX family —
so the obligation is currently **unmet**. This spec closes that gap.

Apache-2.0 note: metal-cpp ships only `LICENSE.txt` (no `NOTICE` file) and is
used unmodified, so reproducing its license text + attribution suffices.

## Scope

**In scope:** every *third-party* component that is actually compiled into or
linked by the **iOS app target** (`KataGo Anytime`), verified by auditing the
Xcode project's compile sources, header-only `#include` sites, and SwiftPM
pins.

**Verified component list (16):**

| # | Component | License | Copyright | Ships via |
|---|-----------|---------|-----------|-----------|
| 1 | KataGo | MIT | David J Wu ("lightvector") | engine (`cpp/`) |
| 2 | abseil-cpp | Apache-2.0 | Google | `cpp/external/abseil-cpp-20260107.1` |
| 3 | ghc::filesystem | MIT | Steffen Schümann | `cpp/external/filesystem-1.5.8` |
| 4 | nlohmann/json | MIT | Niels Lohmann | `cpp/external/nlohmann_json` (+ MLX) |
| 5 | Protocol Buffers | BSD-3-Clause | Google | `cpp/external/protobuf-34.1` |
| 6 | TCLAP | MIT | Michael E. Smoot et al. | `cpp/external/tclap-1.2.5` |
| 7 | coremltools | BSD-3-Clause | Apple Inc. | `katagocoreml/vendor/mlmodel` |
| 8 | FP16 | MIT | Facebook Inc. | `katagocoreml/vendor/deps/FP16` |
| 9 | sha2 | BSD-3-Clause | Aaron D. Gifford | `cpp/core/sha2.cpp` (embedded) |
| 10 | MLX | MIT | Apple Inc. | `ThirdParty/mlx-swift/.../mlx` |
| 11 | mlx-c | MIT | ml-explore | `ThirdParty/mlx-swift/.../mlx-c` |
| 12 | mlx-swift | MIT | ml-explore | `ThirdParty/mlx-swift` |
| 13 | metal-cpp | Apache-2.0 | Apple Inc. | `ThirdParty/mlx-swift/.../metal-cpp` |
| 14 | {fmt} | MIT | Victor Zverovich | `ThirdParty/mlx-swift/.../fmt` |
| 15 | pocketfft | BSD-3-Clause | Max-Planck-Society; Peter Bell | `ThirdParty/mlx-swift/.../mlx/3rdparty` |
| 16 | swift-numerics | MIT | Apple Inc. | SwiftPM (pulled by mlx-swift) |

**Out of scope (verified NOT shipped on iOS):** clblast (OpenCL), cudnn-frontend
(CUDA), half (CUDA/OpenCL-only includes), cpp-httplib + mozilla-cacerts
(`cpp/distributed/` is not compiled — 0 refs in pbxproj), onnx, sgfmill.
`katagocoreml` glue itself is first-party (© Chin-Chang Yang), so it is not
listed as third-party (its vendored coremltools + FP16 are listed as #7/#8).

**Non-goals:** No SwiftData model changes. No C++ changes. No runtime license
fetching. No automated license generation/build script. No change to which
backends ship.

## Architecture (approved: A1 + B1 + C1)

- **A1 — Storage:** license texts embedded as Swift string constants in one new
  data file. No Copy-Bundle-Resources phase changes; the text is guaranteed to
  travel with the binary; only one pbxproj source registration needed.
- **B1 — Placement:** a third `NavigationLink` ("Open-Source Licenses") in the
  existing *Configurations* list (`ConfigView`), sibling to *Global Settings*
  and *Game Settings*.
- **C1 — Structure:** `List` of components (name + license-type subtitle) →
  `NavigationLink` → detail view with the full verbatim license text in a
  scrollable, monospaced `Text`.

## Components / Files

**New: `ThirdPartyLicense` model + data — `ThirdPartyLicenses.swift`**
- `struct ThirdPartyLicense: Identifiable { let id: String /* name */; let name: String; let subtitle: String /* e.g. "MIT · Apple Inc." */; let text: String }`
- `extension ThirdPartyLicense { static let all: [ThirdPartyLicense] = [ ... 16 entries ... ] }`
- Each `text` is the verbatim license, gathered from the corresponding
  `LICENSE` file / source header during implementation. Sorted alphabetically
  by `name` (KataGo pinned first is acceptable).

**New: `AcknowledgmentsView.swift`**
- `AcknowledgmentsView`: `List(ThirdPartyLicense.all) { NavigationLink(...) { LicenseDetailView(license:) } }`, rows show `name` + `subtitle`. `.navigationTitle("Open-Source Licenses")`.
- `LicenseDetailView`: `ScrollView { Text(license.text).font(.system(.footnote, design: .monospaced)) ... }`, `.navigationTitle(license.name)`, `.navigationBarTitleDisplayMode(.inline)`.

**Modify: `ConfigView.swift` (`ConfigView`, ~line 805)**
- Add `NavigationLink("Open-Source Licenses") { AcknowledgmentsView() }` after the *Game Settings* link.

**Modify: `project.pbxproj`**
- Register `ThirdPartyLicenses.swift` and `AcknowledgmentsView.swift` in the
  **KataGo Anytime** app target's Sources phase (via the `xcodeproj` Ruby gem
  snippet — no synchronized groups in this project).

**Modify: `/LICENSE` (repo root)**
- Add the MLX-family components (mlx, mlx-c, mlx-swift, metal-cpp, fmt,
  pocketfft) to the bundled-components attribution paragraph, alongside the
  existing KataGo library list, for source-side attribution.

## Data flow

Static. `ThirdPartyLicense.all` is a compile-time constant array; the views read
it directly. No persistence, no UserDefaults, no SwiftData, no network.

## Error handling

None required — the data is static and exhaustive at compile time. If a `text`
is ever empty the detail view simply shows an empty scroll area; the UI test
guards against the screen being unreachable or empty.

## Testing

Add one XCUITest to the existing UI-test target (`KataGo AnytimeUITests`,
`FullTestPlan`; the simulator pins the backend to CoreML/NE):

- Launch the built-in engine, open *More → Configurations*.
- Assert the **"Open-Source Licenses"** row exists; tap it.
- Assert the list contains key entries, including **"MLX"** (the trigger) and
  at least one more (e.g. "KataGo").
- Tap "MLX"; assert the detail view shows non-empty license text containing
  "MIT" (or "Permission is hereby granted").

Follows the existing `CoreMLCacheFooterUITests` navigation/assertion patterns
(trailing-edge taps where needed, `XCTNSPredicateExpectation` polling).

## Build verification

App must build green for iOS Simulator, macOS, and visionOS Simulator (per
CLAUDE.md). The UI test runs on iOS Simulator only.
