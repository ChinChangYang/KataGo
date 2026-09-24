# 0019 — A style year lives in the profile key

Date: 2026-09-24
Status: Accepted

## Context

Every rank profile sent `humanSLProfile preaz_<rank>`, which tells the human-SL
net's metadata encoder the game is a KGS game from 2016-09-01. The date is a real
input: it is encoded as 32 sin/cos pairs, from a 7-day period up to about 1,500
years, and it is how the net tells a pre-AlphaZero opening from a modern one. We
want each side of a game to choose that year, which we call the *style year*. We
also want the 224 `Pro <year>` menu entries to become a single Pro kind whose year
is set by the same control.

Two things constrain where the year can live:

- The `Config` SwiftData model is frozen: no new stored properties, because it
  syncs through CloudKit and schema drift there is unrecoverable.
- The engine can express a rank profile at only two dates: `preaz_` (2016-09-01)
  and `rank_` (2020-03-01). Only `proyear_<y>` carries an arbitrary year, and it
  is a professional profile (GoGoD/Go4Go source, inverse rank 1), not a KGS rank.

## Decision

1. **The year is part of the stored per-side profile string.** The key is always
   explicit: `AI`, `<rank> <year>` (e.g. `5k 2019`), or `Pro <year>`. This matches
   the shape `Pro 1997` already had. It stays per game and per side, syncs through
   iCloud, and needs no schema change. Legacy keys (`5k`, `preaz_5k`, `rank_5k`)
   read as `5k 2016`, which is what they played before. `proyear_<y>` reads as
   `Pro <y>`.
2. **The engine gains a fork-local `rankyear_<year>_<rank>` profile** (plus the
   asymmetric `rankyear_<year>_<b>_<w>`). It is the `preaz_`/`rank_` KGS profile
   dated `<year>-09-01`, so `rankyear_2016_<r>` is the same metadata as
   `preaz_<r>`. A C++ test pins that equality. The app always sends it for ranks.
   Pro keeps `proyear_<y>` unchanged.
3. **The app offers rank years 2016–2023 and Pro years 1800–2023.** KataGo's own
   human-SL explorer (`python/humanslnet_gui.py`) marks KGS dates before 2016 as
   having no training data. The engine accepts a wider range; the app is the
   gate.
4. **The default is 2016.** The #1209 λ ladder was calibrated at `preaz`, so the
   default leaves every rank exactly where the calibration put it. Other years
   reuse the same λ per rank: the rung is the same, and only the era changes.

## Alternatives rejected

- **Repurpose `humanRatioForBlack/White`** as the year. That per-side Float is
  never sent to the engine, but the macOS "Human SL root ratio" row writes it and
  it takes part in the symmetric/asymmetric equality check. Reusing it would give
  one column two meanings.
- **App-wide AppStorage per side.** It is not per game and not synced, while the
  rest of a side's AI setup is both.
- **Send `preaz_` for 2016 and the new syntax only for other years.** That keeps
  the GTP transcript byte-identical, but it creates two code paths for one
  concept. The metadata is identical either way.
- **A pre-AZ/post-AZ switch** using only the two dates the engine already knows.
  It needs no engine change, but it is not a year.

## Consequences

- `HumanSLModel` splits a key into kind and year. Every chooser (iOS settings,
  macOS Config Editor and Inspector, tvOS New Game) shows a kind plus a Year. The
  iOS long-press menu keeps the side's year for rank picks and keeps its Pro
  decade→year submenu.
- The fork's `sgfmetadata.cpp` diverges further from upstream. Upstream never
  sees `rankyear_`, and an upstream merge must keep the block.
- Keys are longer (`5k 2016`). Player labels, and tvOS game names such as
  "vs KataGo 5k 2016", show the year.
