# ContentView Parser Extraction — Design

**Date:** 2026-06-13
**Status:** Approved

## Problem

`ContentView.swift` (668 lines) is the most tangled view/state file in the
app (survey tangle score 6/10). It mixes the SwiftUI view, the GTP message
loop, and a large body of **pure text-parsing logic** for the engine's
`showboard` and `kata-analyze` output. That parsing logic has **zero
automated test coverage** — and CI runs only unit tests (FastTestPlan; UI
tests are excluded), so today nothing validates it.

## Goal

Behavior-preserving refactor: extract the pure parsing into two focused,
unit-tested value types, shrinking `ContentView` to thin wrappers that keep
all state mutation where it is. No behavior changes, no new features.

## Constraints

- Behavior must be preserved exactly (this is a refactor).
- Must keep building on iOS, macOS, and visionOS.
- No SwiftData `@Model` schema changes (none needed here).
- New `.swift` files registered in `project.pbxproj` via the `xcodeproj`
  Ruby gem (app target `KataGo Anytime`; tests `KataGo AnytimeTests`).
- New unit tests land in `KataGo AnytimeTests` so they run in CI.

## Components

### New unit 1 — `BoardTextParser.swift` (app target)

Pure, dependency-free. Parses the `showboard` ASCII lines into board state.

```
struct ParsedBoard: Equatable {
    let width: CGFloat
    let height: CGFloat
    let blackStones: [BoardPoint]
    let whiteStones: [BoardPoint]
    let moveOrder: [BoardPoint: Character]
}

enum BoardTextParser {
    static func parse(_ boardText: [String]) -> ParsedBoard
}
```

Absorbs the current `parseStones`, `calculateBoardDimensions`,
`calculateYCoordinate`, and `parseLine`. Exact rules preserved:
- height = `boardText.count - 1`; width = `(boardText.last?.dropFirst(2).count ?? 0) / 2`.
- For each line after the first: y = `(Int(line.prefix(2).trimmed) ?? 1) - 1`;
  for each char in `line.dropFirst(3)`, x = `charIndex / 2`; `"X"`→black,
  `"O"`→white, `char.isNumber`→`moveOrder[point] = char`.
- Drops the no-op `.enumerated()` in the line loop (survey finding); behavior
  identical (the index was unused).

### New unit 2 — `AnalysisLineParser.swift` (app target)

Holds the per-parse context as plain values; no `@State`/`@Environment`.

```
struct ParsedAnalysis: Equatable {
    let info: [BoardPoint: AnalysisInfo]
    let ownershipUnits: [OwnershipUnit]
}

struct AnalysisLineParser {
    let boardWidth: Int
    let boardHeight: Int
    let nextColor: PlayerColor   // == player.nextColorFromShowBoard

    func parse(message: String) -> ParsedAnalysis
}
```

Absorbs `collectAnalysisInfo`, `extractAnalysisInfo`, `matchMovePattern`,
`matchVisitsPattern`, `matchWinratePattern`, `matchScoreLeadPattern`,
`matchUtilityLcbPattern`, `moveToPoint`, `extractOwnershipMean`,
`extractOwnershipStdev`, `extractOwnershipUnits`, `computeDefiniteness`,
`computeOpacity`.

Exact rules preserved:
- `parse` splits `message` on `"info"`; maps `extractAnalysisInfo` over every
  chunk; merges the resulting single-entry dicts into one dict keeping the
  **first** value on key collision (current `reduce`/`merging { current,_ in
  current }`); uses the **last** chunk for ownership.
- `extractAnalysisInfo` requires point+visits+winrate+scoreLead+utilityLcb all
  present, then the guard `visits > 0 || winrate != 0.5`.
- Sign flips when `nextColor == .black`: winrate → `1.0 - winrate`; scoreLead
  → `-scoreLead`; utilityLcb → `-utilityLcb`. White → unchanged.
- `moveToPoint`: regex `([^\d\W]+)(\d+)`, `Coordinate(xLabel:yLabel:width:height:)`,
  then `BoardPoint(x: coordinate.x, y: coordinate.y - 1)`. `matchMovePattern`
  handles `move <vertex>` and `move pass` (→ `BoardPoint.pass(width:height:)`).
- Ownership: `extractOwnershipMean`/`Stdev` validate `count == width*height`;
  iterate `y` from `height-1` through `0`, `x` `0..<width`, index `i++`;
  `whiteness = (mean[i]+1)/2`; digitize with `digit = 5`; `definiteness =
  abs(digitizedWhiteness-0.5)*2`; `scale = max(definiteness, digitizedStdev)*0.65`;
  `opacity = 0.8 / (1 + exp(-100*(scale-0.25)))`.

De-duplications (internal, behavior-identical):
- The three color-flipping float matchers collapse into one private helper,
  e.g. `signedFloat(in:pattern:whenBlack:)`, where winrate passes
  `{ 1.0 - $0 }` and scoreLead/utilityLcb pass `{ -$0 }`. `matchVisits`
  (Int, no flip) and `matchMovePattern` (BoardPoint) stay separate.
- `extractOwnershipMean`/`Stdev` collapse into one private
  `floats(in:pattern:expectedCount:)`.
- The unused `nextColorFromShowBoard` parameter on `extractOwnershipUnits` is
  removed.

### `ContentView.swift` changes (thin wrappers)

- `parseBoardPoints(boardText:)`: `let parsed = BoardTextParser.parse(boardText)`
  then the existing `withAnimation(.none) { ... } completion: { withAnimation(.spring) { stones.moveOrder = parsed.moveOrder } }`
  block, unchanged. `parseStones`/`calculateBoardDimensions`/
  `calculateYCoordinate`/`parseLine`/`adjustBoardDimensionsIfNeeded` move out
  (the dimension-adjust helper stays — it touches `analysis`/`board` state —
  but reads `parsed.width/height`).
- `maybeCollectAnalysis(message:)`: build
  `AnalysisLineParser(boardWidth: Int(board.width), boardHeight: Int(board.height), nextColor: player.nextColorFromShowBoard)`,
  `let parsed = parser.parse(message:)`, then assign `analysis.info = parsed.info`,
  `analysis.ownershipUnits = parsed.ownershipUnits`, keep `Analysis.parseRootVisits`,
  `updateVisitsPerSecond`, the winrate/score bar updates, and
  `gobanState.waitingForAnalysis = parsed.info.isEmpty` (equivalent to the old
  `analysisInfo.isEmpty`).
- The gratuitous `async` on the now-pure wrappers is removed; the `await`s at
  their call sites (all inside `ContentView`) are dropped. `maybeCollectBoard`/
  `maybeCollectAnalysis` may remain `async` (they are awaited from `messaging()`).
- Untouched: `maybeCollectBoard`'s stateful parts (captured-stone regexes,
  `isShowingBoard` toggle, "Next player" detection), `maybeCollectSgf`,
  `maybeCollectPlay`/`postProcessAIMove`, `maybeCollectCheckMove`, the GTP loop.

## Data flow

`messaging()` → `maybeCollectBoard` (state) → `parseBoardPoints` →
`BoardTextParser.parse` → apply to `stones`/`board`. And `maybeCollectAnalysis`
(guarded) → `AnalysisLineParser.parse` → apply to `analysis`/`rootWinrate`/
`rootScore`. Parsers are pure functions of their inputs; all `withAnimation`
and `@State`/`@Environment` mutation stays in `ContentView`.

## Testing

New `KataGo AnytimeTests` (Swift Testing; run in CI via FastTestPlan):

- `BoardTextParserTests`: a known multi-line `showboard` sample → expected
  width/height, black/white `BoardPoint`s, and `moveOrder`; empty input → empty
  `ParsedBoard` with width/height 0.
- `AnalysisLineParserTests`: a sample `info ... move Q16 visits N winrate W
  scoreLead S utilityLcb U ...` line parsed with `nextColor: .white` vs
  `.black` → asserts the exact sign flips and the `visits>0 || winrate≠0.5`
  guard (drops a `visits 0 winrate 0.5` entry, keeps a `visits 0 winrate 0.6`
  entry); `move pass` → pass point; an ownership line with the right element
  count → digitized whiteness/scale/opacity for a sampled point, and an
  ownership line with the wrong count → empty `ownershipUnits`; garbage/empty
  message → empty `ParsedAnalysis`.

Builds verified on iOS, macOS, visionOS.

## Decisions

- Two focused parser types (board vs analysis), not one combined type — they
  share nothing and are each independently testable (user choice).
- Parsers are pure value types; all state mutation/animation stays in
  `ContentView`. The win is that previously-untested parsing logic becomes
  CI-covered, and the most-tangled file shrinks ~40%.
