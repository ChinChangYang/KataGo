# Vector App Icon ("Yotsudomoe") — Design Spec

**Date:** 2026-06-12
**Status:** Approved (visual base locked by user after iterative edge-verified comparison)

## Goal

Replace the blurry raster app icon with a fully *computed* (vector/SVG) icon that:
- renders razor-sharp at any size (fixes the blurred color-edge details),
- is authored as a layered Icon Composer `.icon` bundle (≥2 layers, per WWDC 2026 guidance) so iOS 26+ Liquid Glass can add dynamic depth,
- preserves the original icon's exact design language.

## The original design, decoded

Reverse-engineering the existing `icon1024.png` (sub-pixel circle fits to Sobel edges) revealed the true structure, which several naive readings missed:

1. A disc sits on a flat gold background (`#CC994C`).
2. The disc is split into **four sectors along the diagonals** (not the cardinal axes): top sector white `#E0E0E0`, right black, bottom white, left black — an alternating field.
3. **Four large glossy go stones sit ON the diagonals**, each straddling a sector seam: TL black, TR white, BL white, BR black. Each stone *merges* into the same-colored sector on one side and *contrasts* against the other — producing the signature spinning-pinwheel (yotsudomoe) illusion. The sector seams stay completely hidden beneath the stones.
4. The gold background shows through the center as a **four-pointed concave star (astroid)** between the stones.
5. Measured geometry matches the ideal mutual-tangency construction: with disc radius `R`, stone radius `r = R/(1+√2)`, stone centers at `(±r, ±r)` relative to disc center, and a center gold circle also of radius `r`, the stones are simultaneously tangent to the rim, to each other, and to the gold circle (fitted: r≈190 vs ideal 184 on R=444 — the original was hand-drawn ~3% oversize and asymmetric; the vector cleans this up).

## Locked design parameters

- Canvas: 1024×1024 viewBox, all geometry parametric in code.
- Disc radius `R = 420` (≈82% width — refined margin, safe under the Liquid Glass squircle mask; user choice over the original's ~87% full-bleed).
- Stone/gold-circle radius `r = R/(1+√2) ≈ 174.0`; stone centers `(512±174, 512±174)`.
- Colors: gold `#CC994C`; field white `#E0E0E0`; field black `#0a0a0a`.
- Stones: **faithful glossy** shading (user choice) — bright top-lit ceramic specular via radial gradients (white stone: `#fff → #d2d2d2`; black stone: `#fff` hotspot → `#050505`), matching the original's polished look and keeping merged stones legible. Liquid Glass adds its own treatment on top.
- No baked drop shadows in the final layers — separation comes from the system's per-layer shadow (the preview SVGs use a baked shadow only to simulate this).
- Reference implementation of the full construction: the parametric generator prototyped during design (variant I), to be committed as a Python script in the repo.

## Layer decomposition (3 layers, bottom → top)

1. **Background** — flat gold `#CC994C`, full-bleed square.
2. **Field** — the disc of four diagonal sectors, with a **transparent circular hole** (radius `r`) at center so layer 1's gold reads through as the astroid; transparent outside the disc.
3. **Stones** — the four glossy stones. Floating above the field, the system shadow under this layer separates the black stones from the black sectors.

## Appearance modes

Author the **Default** appearance only; let Liquid Glass derive Dark, Tinted, and Clear automatically (user choice). Tuning individual modes later in Icon Composer remains possible.

## Deliverable

A hand-authored `AppIcon.icon` bundle (Icon Composer format: `icon.json` manifest + the 3 SVG layer files) consumed directly by Xcode 26, **replacing** both `AppIcon.appiconset` and `AppIcon.solidimagestack` for iOS, macOS, and visionOS. A committed parametric generator script regenerates the SVG layers.

## Verification approach

- Re-render layers and flattened composite via `rsvg-convert` at 1024/512/180/120/64 px; inspect inline.
- Edge-verify fidelity against the original using the Sobel-overlay harness built during design (original edges vs render edges, ±2px tolerance). Because the shipped icon uses the 82% margin while the original is ~87%, run the comparison on a **match-geometry render** (generator invoked with `R=444`, stone oversize `k=1.03`); the shipped `R=420, k=1.0` output is the same construction at the approved margin. Accept only deviations explained by the original's hand-drawn asymmetry.
- Build the app for all three platforms; verify the icon appears correctly in simulator/device Home Screen and macOS Dock.

## Risks / build-time tasks

1. **`icon.json` schema is undocumented** — must be verified against a known-good `.icon` produced by Icon Composer / Xcode 26 before trusting a hand-authored manifest. (Mitigation: create a trivial `.icon` in Icon Composer first, or locate one in Xcode templates/SDK.)
2. **Icon Composer location** — ships with Xcode 26 tooling; confirm path on this machine.
3. **SVG feature support in Icon Composer layers** — radial gradients are expected to be supported; if a feature (e.g. `feDropShadow`, unusual filters) is not, the generator must avoid it (current design needs only paths, circles, rects, clip paths, and radial gradients — no filters in final layers).
4. **visionOS** — `.icon` replaces the `solidimagestack`; verify the visionOS build accepts it (else keep the existing image stack for the vision idiom only).
