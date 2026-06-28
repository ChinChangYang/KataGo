# Opening-book assets (KataGoBooks) — build & publish runbook

KataGo Anytime downloads its opening books on demand as compact `.kbook.gz`
files. Those assets are **not** stored in this fork's releases; they live on a
separate **`KataGoBooks`** repo's GitHub Release, built from the HTML books at
<https://katagobooks.org/> by `scripts/build_book_db.py`.

The app catalog (`OpeningBook.allCases` in
`ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Model/OpeningBook.swift`)
points its download URLs at:

```
https://github.com/<owner>/KataGoBooks/releases/download/books-v1/<name>.kbook.gz
```

## One-time bootstrap

1. **Create the repo** `KataGoBooks` (public) under your account. It must NOT be
   this fork (`ChinChangYang/KataGo`) — books are kept out of the engine fork's
   releases on purpose.
2. **Add two files** to the repo root:
   - `build_book_db.py` — copy from `ChinChangYang/KataGo:scripts/build_book_db.py`.
   - `.github/workflows/build-books.yml` — copy from
     `ChinChangYang/KataGo:scripts/katagobooks/build-books.yml` (this directory).
3. **Run the workflow:** Actions ▸ *Build Opening Books* ▸ *Run workflow*. The
   matrix builds all four sizes in parallel and publishes them as assets on the
   `books-v1` release.
4. **Verify** the four assets exist on the release and note each one's exact byte
   size:
   - `book6x6jp-20230525.kbook.gz`
   - `book7jpb40s9435-20210806.kbook.gz`
   - `book8jpb40s9854-20211114.kbook.gz`
   - `book9x9jp-20260226.kbook.gz`
5. **Back-fill the catalog** in `OpeningBook.swift`:
   - Set `releaseBase` to your repo (`https://github.com/<owner>/KataGoBooks/releases/download/books-v1/`).
   - Update each book's `fileSize` to the published byte size. (6×6 is already set
     to the measured 13,507,477; the others are estimates until you publish.)
6. **Smoke test in-app:** download each size in the Opening Books screen, open a
   game of that board size, and toggle the eye to book view — candidate moves
   should render on the board.

## Notes

- **Schema/layout differences are handled automatically.** Older small-board
  books embed `v` (visits) instead of `av` (adjusted visits); the builder falls
  back to `v` (`--v-threshold`, default 0 = include all). Older archives nest
  under `html/`; `build_book_db.py` auto-detects `<dir>/html/root/root.html`.
- **9×9 is large.** Its HTML archive is ~1.3 GB and expands to ~5.3M files; that
  matrix job is slow (tens of minutes) but fits well within the Actions limit.
  A `book9x9jp-20260226.kbook.gz` (~229 MB) already exists on the
  `ChinChangYang/KataGo` `v1.16.4-coreml1` release — you may copy that asset to
  the `books-v1` release instead of rebuilding it, if you prefer.
- **Local build** (one size) for testing:
  ```bash
  curl -L -o book.tar.gz https://katagobooks.org/downloads/book6x6jp-20230525.tar.gz
  mkdir extracted && tar -xzf book.tar.gz -C extracted
  python3 scripts/build_book_db.py --board-size 6 --book-dir extracted \
      --output book6x6jp-20230525.kbook.gz
  ```
