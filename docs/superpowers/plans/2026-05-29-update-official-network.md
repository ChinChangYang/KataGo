# Update Official KataGo Network to b40c768nbt-fdx6d — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Point the app's "Official KataGo Network" entry at the current strongest confidently-rated network, `kata1-zhizi-b40c768nbt-fdx6d`.

**Architecture:** A single metadata edit to one `NeuralNetworkModel` entry. The app downloads the `.bin.gz` and the native C++ `katagocoreml` library converts it to CoreML on-the-fly at runtime, so no `.mlpackage` regeneration is needed. `fileSize` is display-only.

**Tech Stack:** Swift / SwiftUI, Xcode, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-05-29-update-official-network-design.md`

**Branch:** `feature/update-official-network` (based on `feature/remove-coreml-precompile`, which carries the model-picker infrastructure not yet on `master`).

> **Note on TDD:** There is no new automated test in this plan. The only "behavior" is literal metadata values; a test asserting the exact URL/name would merely restate the literal and would require editing on every future network bump (this entry is designed to change irregularly). Verification is the project's standard build + existing test suite, plus a source grep for hardcoded architecture limits.

---

### Task 1: Update the "Official KataGo Network" entry

**Files:**
- Modify: `ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift:75-91`

- [ ] **Step 1: Confirm the current entry text**

Run: `sed -n '75,91p' "ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift"`

Expected: the entry titled `"Official KataGo Network"` whose `url` ends in `kata1-zhizi-b28c512nbt-muonfd2.bin.gz` and whose `fileSize` is `271_447_864`. If the text differs from the `old_string` below, stop and reconcile before editing.

- [ ] **Step 2: Replace the entry**

Apply this exact replacement in `ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift`.

Find (old):

```swift
        .init(
            title: "Official KataGo Network",
            description: """
This is the strongest confidently-rated network in KataGo distributed training. It runs using the Metal backend and may offer faster performance than the built-in model on high-end Macs.

This app will irregularly update the URL for the strongest confidently-rated network. If a new network becomes available, you can keep using your current one or manually switch by deleting it and downloading the latest version.

Name: kata1-zhizi-b28c512nbt-muonfd2.
Uploaded at: 2026-03-22 15:32:56 UTC.
Elo Rating: 14155.6 ± 13.6 - (3,551 games).

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-zhizi-b28c512nbt-muonfd2.bin.gz",
            fileName: "official.bin.gz",
            fileSize: 271_447_864
        ),
```

Replace with (new):

```swift
        .init(
            title: "Official KataGo Network",
            description: """
This is the strongest confidently-rated network in KataGo's distributed training. It runs using the Metal backend, which automatically converts to CoreML for inference on Apple devices. As a 40-block network it is the most accurate option, but it is a large (~824 MB) download and runs slower and uses more power than smaller networks — best suited to capable devices.

This app will irregularly update the URL for the strongest confidently-rated network. If a new network becomes available, you can keep using your current one or manually switch by deleting it and downloading the latest version.

Name: kata1-zhizi-b40c768nbt-fdx6d.
Uploaded at: 2026-05-02 17:09:37 UTC.
Elo Rating: 14501.5 ± 21.6 - (4,296 games).

Board sizes: 2x2 to 37x37.
""",
            url: "https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-zhizi-b40c768nbt-fdx6d.bin.gz",
            fileName: "official.bin.gz",
            fileSize: 863_846_339
        ),
```

Notes:
- `title` and `fileName` are intentionally unchanged (the title is referenced by tests/previews; the entry stays at `allCases[1]`).
- `description`'s opening sentence is rewritten: the old "may offer faster performance than the built-in model on high-end Macs" is false for a 40-block net and is removed.

- [ ] **Step 3: Verify the edit**

Run: `grep -n "b40c768nbt-fdx6d\|863_846_339" "ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift"`

Expected: three matches — the `Name:` line, the `url:` line, and the `fileSize:` line. And:

Run: `grep -c "b28c512nbt-muonfd2" "ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift"`

Expected: `0` (no leftover references to the old network).

---

### Task 2: Grep for hardcoded architecture limits

This network is 768 channels wide — wider than anything currently in `allCases` (max 512). Confirm no Swift/C++ code hardcodes a smaller channel/block/buffer ceiling that this net could exceed.

**Files:** none modified — inspection only.

- [ ] **Step 1: Search the Swift backend interface**

Run:
```bash
grep -rniE "512|c512|maxChannels|numChannels|trunkNumChannels|channelLimit|maxBlocks" "ios/KataGo iOS/KataGo iOS/KataGoInterface" 2>/dev/null
```

Expected: no hardcoded constant that caps channels/blocks below 768. Hits referring to cache keys, board sizes, or unrelated `512`-byte buffers are fine. If a genuine channel/block ceiling < 768 is found, stop and report it — it would block this network at runtime and is out of scope for a metadata edit.

- [ ] **Step 2: Search the C++ Metal/CoreML backend**

Run:
```bash
grep -rniE "maxChannels|numChannels|MAX_.*CHANNEL|channelLimit|hardcoded|static_assert.*channel" cpp/neuralnet/metalbackend.swift cpp/neuralnet/coremlbackend.swift cpp/neuralnet/metalbackend.cpp cpp/neuralnet/coremlbackend.cpp 2>/dev/null
```

Expected: no channel/block ceiling below 768. The converter reads architecture from the model descriptor and is generic. Report anything that looks like a fixed upper bound.

---

### Task 3: Build all three platforms and run tests

**Files:** none modified.

- [ ] **Step 1: Build for iOS Simulator**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Build for macOS**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=macOS' -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Build for visionOS Simulator**

Run:
```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the test suite (iOS Simulator)**

Run:
```bash
xcodebuild test -project "ios/KataGo iOS/KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17'
```
Expected: `** TEST SUCCEEDED **`. In particular `EngineLifecycleTests` (which references the `"Official KataGo Network"` title) and `CoreMLCacheReadinessProjectionTests` (which uses `builtInModel`) pass.

---

### Task 4: Commit

**Files:** the edited Swift file.

- [ ] **Step 1: Commit the change**

```bash
git add "ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift"
git commit -m "feat: update Official network to kata1-zhizi-b40c768nbt-fdx6d

Point the downloadable Official KataGo Network entry at the current
strongest confidently-rated network (Elo 14501.5). Update url, fileSize,
and description; drop the inaccurate \"faster than built-in\" claim.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual verification (out of automated scope)

The 768-channel **runtime** path can only be fully confirmed by exercising it:

1. Launch the app (iOS Simulator or device).
2. In the model picker, download the **Official KataGo Network** (~824 MB) — confirm the displayed size reads `823.83 MB`.
3. Run the engine on this network and confirm it produces analysis (the C++ `katagocoreml` converter handles 768 channels). Watch the console for converter/CoreML errors.

If this fails with an architecture/channel error, the fix is a backend change, not a metadata change, and would be tracked separately.

## Self-Review

- **Spec coverage:** url/fileSize/description changes → Task 1. Grep for hardcoded limits → Task 2. Build all 3 platforms + tests → Task 3. Title/position unchanged, no `.mlpackage` work → reflected in Task 1 notes. 768-channel runtime risk → Manual verification section. All spec sections covered.
- **Placeholders:** none — every step has exact code/commands and expected output.
- **Type consistency:** no new types/signatures introduced; only literal field values change within the existing `NeuralNetworkModel.init`.
