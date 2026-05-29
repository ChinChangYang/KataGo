# Update the Official KataGo Network to b40c768nbt-fdx6d

**Date:** 2026-05-29
**Status:** Approved

## Goal

Update the **"Official KataGo Network"** entry in the KataGo Anytime app to point
to the strongest confidently-rated network currently listed on
<https://katagotraining.org/networks/>: `kata1-zhizi-b40c768nbt-fdx6d`.

This replaces the previous official network, `kata1-zhizi-b28c512nbt-muonfd2`.

## Background

`NeuralNetworkModel.swift` defines `allCases`, the list of networks shown in the
app's model picker. The second entry (`allCases[1]`), titled
**"Official KataGo Network"**, is a *downloadable* network whose own description
states it "will irregularly update the URL for the strongest confidently-rated
network." Updating this entry is exactly the maintenance task it was designed
for.

The strongest confidently-rated network as of 2026-05-29:

| Field | Value |
|-------|-------|
| Name | `kata1-zhizi-b40c768nbt-fdx6d` |
| Architecture | b40c768nbt (40 blocks, 768 channels) |
| Elo | 14501.5 ± 21.6 (4,296 games) |
| Uploaded | 2026-05-02 17:09:37 UTC |
| Download | `https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-zhizi-b40c768nbt-fdx6d.bin.gz` |
| File size | 863,846,339 bytes (verified via HTTP `content-length`) |

## Scope

A single-file metadata edit to the `"Official KataGo Network"` entry in
`ios/KataGo iOS/KataGo iOS/NeuralNetworkModel.swift`. Nothing else changes.

Why nothing else changes:

- **No manual CoreML conversion.** The app downloads the `.bin.gz` and the
  native C++ `katagocoreml` library converts it to CoreML on-the-fly at runtime
  (Metal backend). There is no bundled `.mlpackage` to regenerate.
- **`fileSize` is display-only.** It is rendered via `ModelPickerView` →
  `humanFileSize` and is not used for download validation. It is updated anyway
  for an accurate UI.
- **Title and list position are unchanged.** The title string
  `"Official KataGo Network"` is referenced by `EngineLifecycleTests` and by
  `ModelPickerView` previews via the index `allCases[1]`. Keeping the title and
  the entry's position avoids any test/preview breakage.
- **No migration concern.** The app is unreleased (no users), so reusing the
  existing `fileName: "official.bin.gz"` is fine — there are no stale downloads
  to invalidate.

## Field changes

In the `"Official KataGo Network"` entry only:

| Field | From | To |
|-------|------|----|
| `url` | `…/kata1-zhizi-b28c512nbt-muonfd2.bin.gz` | `…/kata1-zhizi-b40c768nbt-fdx6d.bin.gz` |
| `fileSize` | `271_447_864` | `863_846_339` |
| `fileName` | `official.bin.gz` | *(unchanged)* |
| `title` | `Official KataGo Network` | *(unchanged)* |

## Description copy

The current description claims the official net "may offer faster performance
than the built-in model on high-end Macs." That is inaccurate for a 40-block net
(it is slower and more power-hungry than the b18 built-in). Replace the entry's
`description` with accurate copy:

```
This is the strongest confidently-rated network in KataGo's distributed
training. It runs using the Metal backend, which automatically converts to
CoreML for inference on Apple devices. As a 40-block network it is the most
accurate option, but it is a large (~824 MB) download and runs slower and uses
more power than smaller networks — best suited to capable devices.

This app will irregularly update the URL for the strongest confidently-rated
network. If a new network becomes available, you can keep using your current
one or manually switch by deleting it and downloading the latest version.

Name: kata1-zhizi-b40c768nbt-fdx6d.
Uploaded at: 2026-05-02 17:09:37 UTC.
Elo Rating: 14501.5 ± 21.6 - (4,296 games).

Board sizes: 2x2 to 37x37.
```

The "~824 MB" figure matches what the picker shows for this entry: `humanFileSize`
formats bytes in base-1024 with decimal-style unit labels, so 863,846,339 bytes
renders as "823.83 MB".

## Verification

- **Build** all three platforms (iOS Simulator, macOS, visionOS Simulator) and
  run the test suite on the iOS Simulator. A metadata edit will not break
  compilation, but this is the project's standard gate and confirms the test
  references to `"Official KataGo Network"` / `allCases[1]` still hold.
- **Grep** the Swift and C++ backend sources for any hardcoded channel / block /
  buffer limits that a 768-channel network could exceed.

## Risk

`b40c768nbt` uses **768 channels**, wider than any network currently in
`allCases` (the existing 40-block nets are c256-class; the widest is b28's 512
channels). The on-the-fly C++ CoreML converter is generic and is expected to
handle it, but the 768-channel **runtime** path cannot be fully verified without
downloading the 864 MB net and running it on the Neural Engine. This is called
out as a one-time manual confirmation (download + run the net once on a device
or simulator); it is outside the automated build/test gate.
