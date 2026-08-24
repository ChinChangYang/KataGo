# 0009 — Opening books stay within the one-byte board

Date: 2026-08-24
Status: Accepted

Custom opening-book import (and book eligibility generally) covers square
boards from 2×2 to 15×15 and nothing larger, because the KBOK v1 format stores
each move position in a single byte with `N*N` as the pass sentinel — 15×15
(225 + pass) is the largest board that fits, and 19×19 does not. We chose to
ship import on the existing v1 format rather than mint a two-byte v2, because
there is no producer of 19×19 `.kbook` data today: katagobooks.org publishes
small-board books, KataGo's own `genbook` emits `.katabook` (which the app has
never read), and the app's `scripts/build_book_db.py` builder is v1-only.

## Consequences

- `Config.isBookEligible` is `square && (2...15)` — the format's whole range,
  not the catalog's 6…9. Sizes 10…15 behave like an undownloaded catalog size
  until the user imports a book for them.
- A book whose header declares version ≠ 1 is rejected with a **distinct**
  "unsupported book version" error (`BookLookup.BookValidationError
  .unsupportedVersion`, surfaced by `CustomBookImportError
  .unsupportedBookVersion`) at both import and load, so a future v2 file fails
  legibly today.
- 19×19 support arrives, if ever, as a v2 parser plus an eligibility widening —
  not as a shim on the v1 layout.
