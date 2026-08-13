# Play vs KataGo on tvOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the TV library, start a customized game against KataGo (board size, ruleset, certified human-SL rank, classic handicap), play it with the game controller or Siri Remote, and have the game sync to the user's other devices.

**Architecture:** The human net gets bundled and loaded on tvOS (a two-line bridge change plus a pbxproj resource); handicap lives entirely in the SGF (`HA[n]AB[...]PL[W]`) via a new builder on top of the star-point rule, which moves down into `KataGoGameStore` so every layer can share it; a new `TVPlayScreen` runs the standard shared turn-observer gen-move loop (BoardView's `.onChange(of: player.nextColorForPlayCommand)`) with the proven review-screen input stack; a pure `TVPlayability` classifier routes library records to play-vs-review; a pure `TVNewGameForm` model backs the New Game screen. Review and self-play invariants are untouched.

**Tech Stack:** SwiftUI (tvOS 26), SwiftData + CloudKit (`SharedModelContainer.shared`), Swift Testing, the in-process C++ engine over GTP, the `xcodeproj` Ruby gem for project edits.

**Spec:** `docs/superpowers/specs/2026-08-10-tvos-play-vs-katago-design.md`

## Global Constraints

- SwiftData `@Model` schemas are FROZEN (CloudKit): no new stored fields on `Config`/`GameRecord`. Handicap rides in the SGF only.
- English-only committed content — no CJK anywhere in any diff.
- `session.autoCreatesGameOnEmptyLibrary` stays `false` on tvOS (`TVRootView.swift:237`).
- tvOS engine shape unchanged: device assignments `[100]`, `KataGoHelper.mlxNnMaxBatchSize = 2` (part of the compiled-CoreML-model cache key), 1 MB engine thread stack, `maxBoardSizeForNNBuffer` from `TVEngineController.maxBoardLength`.
- Review/self-play invariants untouched: `TVReviewScreen` stays a locked spectator (`suppressesGenMove = true`, `isEditing = false`, `forcesBranchOnPlay = true`); `TVSelfPlayScreen`'s broadcast protocol is not modified.
- `boardFits(width:height:maxBoardLength:)` gate BEFORE any game load or analysis request on every entry path — `NNEvaluator::evaluate` aborts the whole process on an oversized board (`BackendChoice.swift:87-97`).
- tvOS focus rules: no bare `.onTapGesture`; the `tvSelectPress` window-level catcher must be the only Select consumer while enabled; never leave a screen with zero focusables.
- Builds/tests: NEVER run two `xcodebuild`/simulator jobs concurrently (DerivedData lock ⇒ spurious failures). Judge outcomes by grepping the literal `** TEST SUCCEEDED **` / `** BUILD SUCCEEDED **` markers — piped exit codes lie. Unit tests live in target **`KataGo AnytimeTests`** (folder `KataGo iOSTests/`), run on `platform=iOS Simulator,name=iPhone 17`. SwiftPM package tests NEVER run under xcodebuild — run `swift test` from `ios/KataGo iOS/KataGoUICore`.
- New **app-target** Swift files must be registered in the pbxproj: `cd "ios/KataGo iOS" && ruby scripts_add_swift_files.rb "<target name>" "<path/to/File.swift>"`. New **unit-test** files use the inline snippet (see Task 2 Step 6). Package source/test files under `KataGoUICore/Sources|Tests` need NO registration (SwiftPM globs).
- Do NOT push `ios-dev` (every push distributes via Xcode Cloud → TestFlight). Local commits only.
- Use `trash`, never `rm`, to delete files.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RQscogagopHKTm73HDUZ2r
  ```

**Key pre-verified facts** (recon 2026-08-11, so implementers do not re-derive them):

- `KataGoUICore` (the package target) does NOT depend on `GoRulesKit` — the dependency direction is `GoRulesKit → KataGoGameStore` (via `BoardStarPoints`). That is why the handicap placement rule moves DOWN into `KataGoGameStore` (Task 1) instead of the SGF builder reaching up.
- The TV app target does NOT link the `GoRulesKit` product and must not need to.
- `GoGame.handicapPoints` exact domain: non-empty needs both axes odd and ≥ 7 (corners exist); counts 5/7/9 need the center (both axes with 3 star lines); counts 6–9 need side stars, which exist only when BOTH axes are ≥ 15. So 19×19 → 2–9; 9×9 and 13×13 → 2–5; 9×13 → 2–5; even or < 7 axes → none.
- The C++ SGF parser honors root-node `AB[...]` (`SgfNode::accumPlacements`) and `PL[W]` (`getPLSpecifiedColor`), and even without `PL`, all-black placements make White the next player (`CompactSgf::setupInitialBoardAndHist`, `cpp/dataio/sgf.cpp:1817-1848`).
- `GoRulesKit.SgfReplay` already applies `setupBlack`/`setupWhite` from `SgfHeaderScan` (`SgfReplay.swift:56-64`) — watch replay of synced handicap games is covered; only `SgfHeaderScan.toMove` needs the White-first rule (Task 2).
- The iOS Safari appex passes `includeHumanNet: false` explicitly (`KataGoAnytimeSafariExtIOS/IOSEngineController.swift:225`); `ci_scripts/ci_post_clone.sh:118-124` already downloads `b18c384nbt-humanv0.bin.gz`; the shared pbxproj file reference is `E16BC83C2C4D2B2C00EA3A1E`, and the TV target's Resources phase is `C223463320988BF0061CB6F0` (currently WITHOUT the human net).
- `TVControllerInput` already auto-repeats `leftShoulder`/`rightShoulder` while held (`bindRepeating`, 400 ms initial delay then 125 ms) — "L1 = undo, hold repeats" needs no input-layer work.
- tvOS SwiftUI has NO `Stepper` — custom width/height use `Picker`s.
- `shouldGenMove` / the gen-move branch of `getRequestAnalysisCommands` require `analysisStatus == .run`. "Analysis overlays default OFF" therefore means `eyeStatus` closed (display off) with `analysisStatus = .run` (engine on): `isAnalysisHiddenForPowerSaving` then suppresses analyze on the human's turn while the engine's gen-move turns are unaffected. Never use `.clear` to hide overlays on the play screen — that kills the AI's moves.

---

### Task 1: Move the handicap placement rule into KataGoGameStore

The star-point rule (`BoardStarPoints`) already lives in `KataGoGameStore`, the bridge-free base target every product links. The handicap-ordering logic on top of it currently lives one level up in `GoRulesKit` (`GoGame.handicapPoints`). Move the logic down (new `BoardHandicapPoints`), have `GoGame` delegate, and expose the SGF coordinate mapper beside it. This unblocks Task 2's SGF builder in `KataGoGameStore` with zero dependency changes for any target.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/BoardHandicapPoints.swift`
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/GoGame.swift:126-172` (delegate `handicapPoints` + `maxHandicap`)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/GoRulesKit/MessageGameCodec.swift:282-285` (delegate `sgfCoord`)
- Modify: `ios/KataGo iOS/KataGoUICore/Package.swift` (add `"KataGoGameStore"` to the `GoRulesKitTests` test target's dependencies)
- Test: `ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/BoardHandicapPointsTests.swift`

**Interfaces:**
- Produces: `public enum BoardHandicapPoints` in `KataGoGameStore` with
  - `static func points(width: Int, height: Int, count: Int) -> [(x: Int, y: Int)]` — top-left origin, conventional order (Black's first stone top-right), all-or-nothing (`[]` when the board has no layout for `count`).
  - `static func maxCount(width: Int, height: Int) -> Int` — largest n in 9…2 with a full layout, else 0.
  - `static func sgfCoordinate(x: Int, y: Int) -> String?` — `a…z` then `A…Z` per axis, `nil` at ≥ 52.
- `GoGame.handicapPoints(width:height:count:) -> [GoPoint]` and `GoGame.maxHandicap(width:height:)` keep their exact signatures and behavior (pure delegation).

- [ ] **Step 1: Write the failing test**

Create `BoardHandicapPointsTests.swift` in `KataGoUICore/Tests/GoRulesKitTests/`:

```swift
import Testing
import KataGoGameStore
import GoRulesKit

struct BoardHandicapPointsTests {
    @Test("19x19 supports the full 2-9 ladder in conventional order")
    func nineteenFullLadder() {
        for n in 2...9 {
            #expect(BoardHandicapPoints.points(width: 19, height: 19, count: n).count == n)
        }
        let two = BoardHandicapPoints.points(width: 19, height: 19, count: 2)
        #expect(two.map { [$0.x, $0.y] } == [[15, 3], [3, 15]])
    }

    @Test("9x9 and 13x13 cap at five stones")
    func smallSquaresCapAtFive() {
        for size in [9, 13] {
            #expect(BoardHandicapPoints.maxCount(width: size, height: size) == 5)
            #expect(BoardHandicapPoints.points(width: size, height: size, count: 5).count == 5)
            for n in 6...9 {
                #expect(BoardHandicapPoints.points(width: size, height: size, count: n).isEmpty)
            }
        }
    }

    @Test("rectangles and layout-free boards")
    func rectanglesAndEmptyDomains() {
        #expect(BoardHandicapPoints.maxCount(width: 9, height: 13) == 5)
        #expect(BoardHandicapPoints.points(width: 9, height: 13, count: 4).count == 4)
        #expect(BoardHandicapPoints.points(width: 9, height: 13, count: 6).isEmpty)
        #expect(BoardHandicapPoints.maxCount(width: 8, height: 8) == 0)
        #expect(BoardHandicapPoints.maxCount(width: 5, height: 5) == 0)
        #expect(BoardHandicapPoints.maxCount(width: 2, height: 19) == 0)
    }

    @Test("GoGame delegation is byte-identical")
    func delegationMatchesGoGame() {
        for (w, h, n) in [(19, 19, 9), (19, 19, 2), (13, 13, 5), (9, 13, 4), (9, 9, 6)] {
            let a = BoardHandicapPoints.points(width: w, height: h, count: n).map { [$0.x, $0.y] }
            let b = GoGame.handicapPoints(width: w, height: h, count: n).map { [$0.x, $0.y] }
            #expect(a == b)
        }
    }

    @Test("SGF coordinates")
    func sgfCoordinates() {
        #expect(BoardHandicapPoints.sgfCoordinate(x: 0, y: 0) == "aa")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 15, y: 3) == "pd")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 3, y: 15) == "dp")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 26, y: 0) == "Aa")
        #expect(BoardHandicapPoints.sgfCoordinate(x: 52, y: 0) == nil)
    }
}
```

Also add `"KataGoGameStore"` to the `GoRulesKitTests` test target's `dependencies` array in `KataGoUICore/Package.swift` (find the `.testTarget(name: "GoRulesKitTests", ...)` entry; it currently depends only on `"GoRulesKit"`).

- [ ] **Step 2: Run to verify it fails**

```bash
cd "ios/KataGo iOS/KataGoUICore" && swift test --filter GoRulesKitTests 2>&1 | tail -20
```

Expected: compile FAILURE — `BoardHandicapPoints` not found.

- [ ] **Step 3: Implement BoardHandicapPoints and delegate**

Create `KataGoUICore/Sources/KataGoGameStore/BoardHandicapPoints.swift`. Port the body of `GoGame.handicapPoints` (`GoRulesKit/GoGame.swift:126-164`) VERBATIM in logic — same corner order (top-right, bottom-left, bottom-right, top-left), same center rule (`xs.count == 3 && ys.count == 3`), same side ordering (left/right middles before top/bottom middles), same all-or-nothing return — using a private `struct P: Equatable { let x: Int; let y: Int }` internally (labeled tuples are not `Equatable` for `contains`), mapped from `BoardStarPoints.points(width:height:)`:

```swift
import Foundation

/// Conventional handicap-stone placement, derived from `BoardStarPoints`
/// (the star-point rule it lives beside). Top-left origin, matching
/// BoardStarPoints and the SGF coordinate system. The single source of
/// truth: `GoGame.handicapPoints` (GoRulesKit) and `GameRecord.makeSgf`'s
/// handicap overload both delegate here.
public enum BoardHandicapPoints {
    private struct P: Equatable { let x: Int; let y: Int }

    public static func points(width: Int, height: Int, count: Int) -> [(x: Int, y: Int)] {
        let stars = BoardStarPoints.points(width: width, height: height).map { P(x: $0.x, y: $0.y) }
        guard count >= 2 else { return [] }
        let xs = Set(stars.map(\.x)).sorted()
        let ys = Set(stars.map(\.y)).sorted()
        guard xs.count >= 2, ys.count >= 2 else { return [] }
        let (left, right) = (xs.first!, xs.last!)
        let (top, bottom) = (ys.first!, ys.last!)
        func star(_ x: Int, _ y: Int) -> P? { stars.first { $0.x == x && $0.y == y } }
        // Black's first stone top-right, then diagonal, per convention.
        let corners = [star(right, top), star(left, bottom), star(right, bottom), star(left, top)]
            .compactMap { $0 }
        let center = stars.first { xs.count == 3 && ys.count == 3 && $0.x == xs[1] && $0.y == ys[1] }
        // Traditional order: the left/right middle points come before the
        // top/bottom middle points (6-stone handicap = corners + both sides).
        let sides = stars.filter { p in !corners.contains(p) && center != p }
            .sorted { a, b in
                let aIsLeftRight = center.map { a.y == $0.y } ?? false
                let bIsLeftRight = center.map { b.y == $0.y } ?? false
                if aIsLeftRight != bIsLeftRight { return aIsLeftRight }
                return a.x != b.x ? a.x < b.x : a.y < b.y
            }
        var order: [P] = []
        switch count {
        case 2, 3, 4:
            order = Array(corners.prefix(count))
        case 5, 7, 9:
            guard let center else { return [] }
            order = Array(corners.prefix(4)) + sides.prefix(count - 5) + [center]
        case 6, 8:
            order = Array(corners.prefix(4)) + sides.prefix(count - 4)
        default:
            return []
        }
        guard order.count == count else { return [] }
        return order.map { (x: $0.x, y: $0.y) }
    }

    public static func maxCount(width: Int, height: Int) -> Int {
        for n in stride(from: 9, through: 2, by: -1)
        where points(width: width, height: height, count: n).count == n {
            return n
        }
        return 0
    }

    /// SGF point letters: a-z for 0-25, A-Z for 26-51, nil beyond (the SGF
    /// coordinate alphabet ends at 52; this app caps boards at 37 anyway).
    public static func sgfCoordinate(x: Int, y: Int) -> String? {
        func letter(_ v: Int) -> Character? {
            if (0..<26).contains(v) { return Character(UnicodeScalar(UInt8(97 + v))) }
            if (26..<52).contains(v) { return Character(UnicodeScalar(UInt8(65 + v - 26))) }
            return nil
        }
        guard let cx = letter(x), let cy = letter(y) else { return nil }
        return "\(cx)\(cy)"
    }
}
```

Then in `GoRulesKit/GoGame.swift`, replace the bodies of `handicapPoints` and `maxHandicap` (keep signatures and doc comments):

```swift
public static func handicapPoints(width: Int, height: Int, count: Int) -> [GoPoint] {
    BoardHandicapPoints.points(width: width, height: height, count: count)
        .map { GoPoint(x: $0.x, y: $0.y) }
}

public static func maxHandicap(width: Int, height: Int) -> Int {
    BoardHandicapPoints.maxCount(width: width, height: height)
}
```

In `MessageGameCodec.swift`, read the current `sgfCoord(_ p: GoPoint) -> String` body first, then delegate while preserving its exact output for 0…51 (boards cap at 37, so ≥ 52 is unreachable; keep whatever the current code does there or fall back to `""`):

```swift
static func sgfCoord(_ p: GoPoint) -> String {
    BoardHandicapPoints.sgfCoordinate(x: p.x, y: p.y) ?? ""
}
```

- [ ] **Step 4: Run package tests**

```bash
cd "ios/KataGo iOS/KataGoUICore" && swift test --filter GoRulesKitTests 2>&1 | tail -10
```

Expected: PASS, including the pre-existing `handicapGameStartsWithWhiteAndPlacesConventionalStones` and the SgfReplay suites — check the `Test run with N tests ... passed` line.

- [ ] **Step 5: Run the engine differential suite (delegation equivalence against the C++ board)**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/GoRulesKitDifferentialTests" 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **` with a non-zero test count (the handicap 2/3 scenarios replay through the engine).

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS/KataGoUICore"
git commit -m "refactor(rules): move the handicap placement rule into KataGoGameStore"
```

---

### Task 2: Handicap SGF builder + White-to-move header scan

Add `GameRecord.makeSgf(width:height:komi:ruleString:handicap:)` emitting `HA[n]AB[...]PL[W]`, teach `SgfHeaderScan.toMove` the White-moves-first rule (so the watch/widget show the right color for a fresh synced handicap game), and prove the builder's output through the C++ engine parser.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoGameStore/GameRecord.swift` (new overload beside `makeSgf` at L45-48)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoAnalysisKit/SgfHeaderScan.swift` (PL parsing + `toMove` fallback)
- Test: `ios/KataGo iOS/KataGoUICore/Tests/GoRulesKitTests/HandicapSgfTests.swift` (pure string, `swift test`)
- Test: `ios/KataGo iOS/KataGoUICore/Tests/KataGoAnalysisKitTests/SgfHeaderScanHandicapTests.swift` (`swift test`)
- Test: `ios/KataGo iOS/KataGo iOSTests/HandicapSgfEngineTests.swift` (engine round-trip; needs pbxproj registration)

**Interfaces:**
- Consumes: `BoardHandicapPoints.points/sgfCoordinate` (Task 1), `GameRecord.makeSgf(width:height:komi:ruleString:)` and `komiSgfField(_:)` (existing, `KataGoGameStore/GameRecord.swift:45-56`).
- Produces: `public static func makeSgf(width: Int, height: Int, komi: Float, ruleString: String, handicap: Int) -> String?` on `GameRecord` — `handicap == 0` delegates to the plain builder (non-nil); `2...9` emits the handicap root or `nil` when the board has no layout; any other handicap → `nil`. `SgfHeaderScan` gains `public let nextPlayerOverride: PlayerColor?` (from `PL[...]`), and `toMove(atMoveIndex:)` resolves a no-moves scan as: PL override → all-black-setup ⇒ `.white` → `.black`.

- [ ] **Step 1: Write the failing builder tests**

Create `KataGoUICore/Tests/GoRulesKitTests/HandicapSgfTests.swift` (this test target now imports `KataGoGameStore` after Task 1; no bridge, pure strings):

```swift
import Testing
import KataGoGameStore

struct HandicapSgfTests {
    @Test("two-stone 19x19 emits HA, AB on the conventional points, PL[W]")
    func nineteenTwoStone() {
        let sgf = GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                     ruleString: "japanese", handicap: 2)
        #expect(sgf == "(;FF[4]GM[1]SZ[19]PB[]PW[]HA[2]AB[pd][dp]PL[W]KM[0.5]RU[japanese])")
    }

    @Test("zero handicap matches the plain builder exactly")
    func zeroHandicapMatchesPlainBuilder() {
        let plain = GameRecord.makeSgf(width: 13, height: 9, komi: 7.0,
                                       ruleString: "chinese")
        let viaHandicap = GameRecord.makeSgf(width: 13, height: 9, komi: 7.0,
                                             ruleString: "chinese", handicap: 0)
        #expect(viaHandicap == plain)
    }

    @Test("AB point count and order match BoardHandicapPoints")
    func pointsMatchPlacementRule() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 9, height: 9, komi: 0.5,
                                                  ruleString: "chinese", handicap: 5))
        let expected = BoardHandicapPoints.points(width: 9, height: 9, count: 5)
            .compactMap { BoardHandicapPoints.sgfCoordinate(x: $0.x, y: $0.y) }
            .map { "[\($0)]" }
            .joined()
        #expect(sgf.contains("HA[5]AB\(expected)PL[W]"))
    }

    @Test("boards without a layout refuse the handicap")
    func unsupportedHandicapIsNil() {
        #expect(GameRecord.makeSgf(width: 9, height: 9, komi: 0.5,
                                   ruleString: "chinese", handicap: 6) == nil)
        #expect(GameRecord.makeSgf(width: 8, height: 8, komi: 0.5,
                                   ruleString: "chinese", handicap: 2) == nil)
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                   ruleString: "chinese", handicap: 1) == nil)
        #expect(GameRecord.makeSgf(width: 19, height: 19, komi: 0.5,
                                   ruleString: "chinese", handicap: 10) == nil)
    }

    @Test("rectangles keep the w:h size field")
    func rectangleSizeField() throws {
        let sgf = try #require(GameRecord.makeSgf(width: 9, height: 13, komi: 0.5,
                                                  ruleString: "aga", handicap: 3))
        #expect(sgf.contains("SZ[9:13]"))
        #expect(sgf.contains("HA[3]"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd "ios/KataGo iOS/KataGoUICore" && swift test --filter GoRulesKitTests 2>&1 | tail -10
```

Expected: compile FAILURE — no `makeSgf(width:height:komi:ruleString:handicap:)` overload.

- [ ] **Step 3: Implement the builder**

In `KataGoGameStore/GameRecord.swift`, directly below the existing `makeSgf(width:height:komi:ruleString:)`:

```swift
/// SGF for a fresh classic-handicap game: `HA[n]` + `AB[...]` on the
/// conventional star points (stones always Black's) and White to move
/// (`PL[W]` — belt-and-suspenders: the engine's parser also infers White
/// from all-black placements). Returns `nil` when the board has no
/// star-point layout for `handicap` (see `BoardHandicapPoints`) — callers
/// disable those choices up front. `handicap == 0` delegates to the plain
/// builder. Komi is the caller's; the New Game flow passes 0.5 for
/// handicap games.
public static func makeSgf(width: Int, height: Int, komi: Float,
                           ruleString: String, handicap: Int) -> String? {
    guard handicap != 0 else {
        return makeSgf(width: width, height: height, komi: komi, ruleString: ruleString)
    }
    let points = BoardHandicapPoints.points(width: width, height: height, count: handicap)
    guard points.count == handicap else { return nil }
    var setup = ""
    for point in points {
        guard let coordinate = BoardHandicapPoints.sgfCoordinate(x: point.x, y: point.y) else {
            return nil
        }
        setup += "[\(coordinate)]"
    }
    let sizeField = width == height ? "\(width)" : "\(width):\(height)"
    return "(;FF[4]GM[1]SZ[\(sizeField)]PB[]PW[]HA[\(handicap)]AB\(setup)PL[W]KM[\(komiSgfField(komi))]RU[\(ruleString)])"
}
```

- [ ] **Step 4: Run the builder tests** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Write the failing header-scan tests, then implement**

Create `KataGoUICore/Tests/KataGoAnalysisKitTests/SgfHeaderScanHandicapTests.swift` (match the import style of the existing files in that directory):

```swift
import Testing
@testable import KataGoAnalysisKit

struct SgfHeaderScanHandicapTests {
    @Test("PL[W] on a zero-move handicap root reads White to move")
    func plOverrideWhite() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;FF[4]GM[1]SZ[19]HA[2]AB[pd][dp]PL[W]KM[0.5]RU[japanese])"))
        #expect(scan.nextPlayerOverride == .white)
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }

    @Test("all-black setup implies White even without PL (engine parity)")
    func allBlackSetupImpliesWhite() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd][dp])"))
        #expect(scan.nextPlayerOverride == nil)
        #expect(scan.toMove(atMoveIndex: 0) == .white)
    }

    @Test("PL[B] wins over the setup rule")
    func plBlackWins() throws {
        let scan = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd]PL[B])"))
        #expect(scan.toMove(atMoveIndex: 0) == .black)
    }

    @Test("plain empty and mixed-setup boards still open with Black")
    func plainStillBlack() throws {
        let empty = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19])"))
        #expect(empty.toMove(atMoveIndex: 0) == .black)
        let mixed = try #require(SgfHeaderScan(sgf: "(;FF[4]GM[1]SZ[19]AB[pd]AW[dp])"))
        #expect(mixed.toMove(atMoveIndex: 0) == .black)
    }

    @Test("moves still govern when present")
    func movesStillGovern() throws {
        let scan = try #require(SgfHeaderScan(
            sgf: "(;FF[4]GM[1]SZ[19]HA[2]AB[pd][dp]PL[W];W[dd])"))
        #expect(scan.toMove(atMoveIndex: 0) == .black)
    }
}
```

Run `swift test --filter KataGoAnalysisKitTests` — expected FAIL (`nextPlayerOverride` missing). Then implement in `SgfHeaderScan.swift`:

1. Add a stored `public let nextPlayerOverride: PlayerColor?`. Parse it in `init?` beside the SZ/KM/RU regexes (L93-100): match `PL[w]`/`PL[white]`/`PL[b]`/`PL[black]` case-insensitively (the four spellings the C++ `getPLSpecifiedColor` accepts), else `nil`.
2. Extend `toMove(atMoveIndex:)` (L76-79): the existing move-based branches stay byte-identical; ONLY the fallback for "no move at or after the index and no last move to flip" changes from `.black` to:

```swift
if let nextPlayerOverride { return nextPlayerOverride }
if !setupBlack.isEmpty && setupWhite.isEmpty { return .white }
return .black
```

Read the current implementation first — the exact branch structure differs from this sketch; the requirement is: when moves exist the current behavior is unchanged, and the empty-tail fallback applies the PL-then-all-black-setup-then-black ladder (mirroring `CompactSgf::setupInitialBoardAndHist`). Update the doc comment gap note (L59-64/L76-79) accordingly.

Re-run `swift test --filter KataGoAnalysisKitTests` AND `swift test --filter GoRulesKitTests` (SgfReplay consumes the scan). Expected: PASS.

- [ ] **Step 6: Engine round-trip test (app target)**

Create `ios/KataGo iOS/KataGo iOSTests/HandicapSgfEngineTests.swift`:

```swift
//
//  HandicapSgfEngineTests.swift
//  KataGo AnytimeTests
//
//  The handicap SGF builder's output, replayed through the C++ engine's
//  own SGF parser (SgfHelper, linked in this test host): frame 0 of the
//  GIF-frame walk is the setup position, so this proves the engine sees
//  exactly the stones BoardHandicapPoints placed, plus the komi.
//

import Testing
import KataGoGameStore
@testable import KataGoUICore

struct HandicapSgfEngineTests {
    /// GTP vertex ("Q16") for a top-left-origin (x, y): column letters skip
    /// "I", rows count up from the bottom edge.
    private func gtpVertex(x: Int, y: Int, height: Int) -> String {
        let letters = Array("ABCDEFGHJKLMNOPQRSTUVWXYZ")
        return "\(letters[x])\(height - y)"
    }

    @Test("engine setup position matches the placement rule", arguments: [
        [19, 19, 9], [19, 19, 2], [13, 13, 5], [9, 13, 4],
    ])
    func engineSetupMatchesPlacement(scenario: [Int]) throws {
        let (width, height, handicap) = (scenario[0], scenario[1], scenario[2])
        let sgf = try #require(GameRecord.makeSgf(width: width, height: height, komi: 0.5,
                                                  ruleString: "japanese", handicap: handicap))
        let frames = SgfHelper(sgf: sgf).gifFrames()
        let setup = try #require(frames.first)
        let expected = Set(
            BoardHandicapPoints.points(width: width, height: height, count: handicap)
                .map { gtpVertex(x: $0.x, y: $0.y, height: height) })
        #expect(Set(setup.blackStones) == expected)
        #expect(setup.whiteStones.isEmpty)
        #expect(SgfOperations(sgf: sgf).rules.komi == 0.5)
    }
}
```

Before finalizing, read `KataGo iOSTests/GoRulesKitDifferentialTests.swift` and align the frame/vertex access with its exact `gifFrames()` frame API (property names for black/white stone lists) — the sketch above matches its comparison style but the property spellings govern. Register the file:

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
proj   = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = proj.targets.find { |t| t.name == "KataGo AnytimeTests" }
anchor = proj.files.find { |f| (f.path || "").end_with?("GoRulesKitDifferentialTests.swift") }
group  = anchor.parent
fname  = "HandicapSgfEngineTests.swift"
unless proj.files.any? { |f| (f.path || "").end_with?(fname) }
  ref = group.new_file(fname)
  target.source_build_phase.add_file_reference(ref, true)
end
proj.save
'
```

Note the gotcha from prior rounds: `new_file` takes the bare filename relative to the group (path-doubling otherwise); the save re-serializes the pbxproj (normal noise).

- [ ] **Step 7: Run the app-target test**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/HandicapSgfEngineTests" 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **` with 4 tests (verify the non-zero count — a mistyped `-only-testing` filter "passes" on 0 tests).

- [ ] **Step 8: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(rules): handicap SGF builder + White-to-move header scan"
```

---

### Task 3: Load the human-SL net on tvOS

Drop the compile-time `skipHumanNet` hardcode so tvOS honors the existing `includeHumanNet` parameter (default `true`), and bundle `b18c384nbt-humanv0.bin.gz` into the TV target. The cfg stripping (`strippedHumanSLConfig`) already keys off `skipHumanNet`, so the `Setup::loadParams` abort trap stays closed automatically — the iOS Safari appex keeps passing `includeHumanNet: false`.

**Files:**
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Bridge/KataGoHelper.swift:88-92`
- Modify: `ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj` (via Ruby, never by hand)
- Verify only (no edit): `ios/KataGo iOS/ci_scripts/ci_post_clone.sh:118-124` (already downloads the net)

**Interfaces:**
- Consumes: `KataGoHelper.runGtp(... includeHumanNet: Bool = true ...)` (existing); `TVEngineController.spawnEngineThread()` leaves the parameter at its default, so no TV-target code change is needed.
- Produces: tvOS launches with BOTH nets resident and the full (unstripped) `default_gtp.cfg` — the `humanSL*` params that previously failed as GTP `?` errors now apply, exactly as on iOS.

- [ ] **Step 1: Drop the hardcode**

In `KataGoHelper.swift` replace:

```swift
#if os(tvOS)
let skipHumanNet = true
#else
let skipHumanNet = !includeHumanNet
#endif
```

with:

```swift
let skipHumanNet = !includeHumanNet
```

Update the surrounding comment: the caller decides — the iOS Safari appex passes `false` (80 MB jetsam budget, `IOSEngineController.swift:225`); every app target, tvOS included, takes the default `true`. `strippedHumanSLConfig` stays keyed off `skipHumanNet`, so a netless launch can never see `humanSL*` cfg lines. If the temp-file name inside `strippedHumanSLConfig` still says `default_gtp_tvos.cfg`, rename it to `default_gtp_stripped.cfg` (it now serves the appex, not tvOS).

- [ ] **Step 2: Bundle the net in the TV target**

```bash
cd "ios/KataGo iOS" && ruby -e '
require "xcodeproj"
project = Xcodeproj::Project.open("KataGo Anytime.xcodeproj")
target = project.targets.find { |t| t.name == "KataGo Anytime TV" } or abort("TV target not found")
ref = project.files.find { |f| (f.path || "").end_with?("b18c384nbt-humanv0.bin.gz") } or abort("missing shared net reference")
phase = target.resources_build_phase
if phase.files.any? { |f| f.file_ref == ref }
  puts "already present"
else
  phase.add_file_reference(ref)
  project.save
  puts "added"
end
'
```

Verify with `git diff "ios/KataGo iOS/KataGo Anytime.xcodeproj/project.pbxproj"`: one new `PBXBuildFile` referencing `E16BC83C2C4D2B2C00EA3A1E` and one new entry in the TV Resources phase (`C223463320988BF0061CB6F0`); nothing else semantic (re-serialization noise is normal).

- [ ] **Step 3: Confirm CI stages the net**

Read `ios/KataGo iOS/ci_scripts/ci_post_clone.sh` around lines 110-130 and confirm the `b18c384nbt-humanv0.bin.gz` download into `../Resources/` is present (it is, per recon). No edit expected — this step exists because a bundled net absent from that script breaks the next fresh Xcode Cloud clone.

- [ ] **Step 4: Build the TV scheme**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Build the iOS scheme (appex unaffected)**

```bash
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Run the unit suite** (the bridge file compiles into the test host)

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): load the human-SL net on tvOS"
```

**Do not change** `mlxNnMaxBatchSize` (2 — compiled-model cache key), the `[100]` device assignment, or `.cpuAndGPU` in `CoreMLComputeHandleLoader`. The memory cost of the second net is the ship risk; its on-device validation is Task 9's gate, and the conditional-restart fallback is designed but built ONLY if that gate fails.

---

### Task 4: TVPlayability classifier + rank-budget re-arm checklist tests

A pure classifier deciding which library records open the play screen, plus the spec's checklist tests that every analyze/gen-move command path used on tvOS deliberately arms `maxVisits` (with the human net loaded, the sticky rank budgets `400/40` now really apply, so a path that forgets to re-arm would silently cripple analysis).

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVPlayability.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/TVPlayabilityTests.swift` (register — same snippet shape as Task 2 Step 6, anchor `TVAutoPlaySpeedTests.swift`)
- Test: `ios/KataGo iOS/KataGo iOSTests/RankCommandRearmTests.swift` (register likewise)

**Interfaces:**
- Consumes: `SelfPlayGame.recordedGameIsFinished(sgf:)` (`KataGoUICore/Model/SelfPlayGame.swift:154-157` — make it `public` if it is internal today), `Config.blackMaxTime/whiteMaxTime`, `GameRecord.concreteConfig`.
- Produces:

```swift
public enum TVPlayability {
    public static func isHumanVsAI(blackMaxTime: Float, whiteMaxTime: Float) -> Bool
    public static func isPlayable(blackMaxTime: Float, whiteMaxTime: Float, sgf: String) -> Bool
    @MainActor public static func isPlayable(_ record: GameRecord) -> Bool
}
```

- [ ] **Step 1: Write the failing classifier tests**

`KataGo iOSTests/TVPlayabilityTests.swift`:

```swift
import Testing
@testable import KataGoUICore

struct TVPlayabilityTests {
    @Test("asymmetric unfinished games are playable, both directions")
    func asymmetricUnfinishedIsPlayable() {
        #expect(TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                         sgf: "(;FF[4]GM[1]SZ[19];B[pd])"))
        #expect(TVPlayability.isPlayable(blackMaxTime: 0.5, whiteMaxTime: 0,
                                         sgf: "(;FF[4]GM[1]SZ[19])"))
    }

    @Test("symmetric configs review instead")
    func symmetricIsNotPlayable() {
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0,
                                          sgf: "(;FF[4]GM[1]SZ[19])"))
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0.5, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19])"))
    }

    @Test("finished games review instead")
    func finishedIsNotPlayable() {
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19]RE[B+3.5];B[pd])"))
        #expect(!TVPlayability.isPlayable(blackMaxTime: 0, whiteMaxTime: 0.5,
                                          sgf: "(;FF[4]GM[1]SZ[19];B[pd];W[];B[])"))
    }
}
```

- [ ] **Step 2: Register both test files, run to verify failure**

Register `TVPlayabilityTests.swift` and `RankCommandRearmTests.swift` (create the second file with a placeholder suite first or register it in Step 4) using the Task 2 Step 6 Ruby snippet with anchor `TVAutoPlaySpeedTests.swift` and target `KataGo AnytimeTests`. Run:

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/TVPlayabilityTests" 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: compile FAILURE (`TVPlayability` unknown).

- [ ] **Step 3: Implement TVPlayability**

`KataGoUICore/Sources/KataGoUICore/Util/TVPlayability.swift`:

```swift
import Foundation
import KataGoGameStore

/// Classifies a library record as "continue playing" (opens TVPlayScreen)
/// vs "review" (locked spectator). Deliberately config-based — exactly one
/// side with maxTime == 0 marks a human-vs-AI game — so a game started on
/// iPhone/iPad/Mac is continuable on the TV.
public enum TVPlayability {
    public static func isHumanVsAI(blackMaxTime: Float, whiteMaxTime: Float) -> Bool {
        (blackMaxTime == 0) != (whiteMaxTime == 0)
    }

    public static func isPlayable(blackMaxTime: Float, whiteMaxTime: Float, sgf: String) -> Bool {
        isHumanVsAI(blackMaxTime: blackMaxTime, whiteMaxTime: whiteMaxTime)
            && !SelfPlayGame.recordedGameIsFinished(sgf: sgf)
    }

    @MainActor
    public static func isPlayable(_ record: GameRecord) -> Bool {
        let config = record.concreteConfig
        return isPlayable(blackMaxTime: config.blackMaxTime,
                          whiteMaxTime: config.whiteMaxTime,
                          sgf: record.sgf)
    }
}
```

Run the Step 2 command again. Expected: `** TEST SUCCEEDED **`, 3 tests.

- [ ] **Step 4: Write the re-arm checklist tests**

`KataGo iOSTests/RankCommandRearmTests.swift`. First read `GtpCommandBuilder.swift` (`KataGoUICore/Session/GtpCommandBuilder.swift:14-80`) and any existing `GtpCommandBuilder`/`BroadcastGenMove` test files to confirm the exact command spellings, then assert:

```swift
import Testing
@testable import KataGoUICore

struct RankCommandRearmTests {
    @Test("rank gen-moves arm the certified visit budgets")
    func rankGenMoveArmsTheRankBudget() {
        let weak = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "3k", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(weak.contains("kata-set-param maxVisits 40"))
        let strong = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "9d", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(strong.contains("kata-set-param maxVisits 400"))
        let pro = GtpCommandBuilder.genMoveAnalyzeCommands(
            effectiveProfile: "Pro 2023", maxTime: 0.5, interval: 50, maxMoves: 50)
        #expect(pro.contains("kata-set-param maxVisits 400"))
    }

    @Test("every continuous-analyze bundle re-arms maxVisits to unbounded")
    func continuousBundlesRearmUnbounded() {
        let slow = GtpCommandBuilder.continuousAnalyzeCommands(interval: 50, maxMoves: 50)
        let fast = GtpCommandBuilder.fastContinuousAnalyzeCommands(maxMoves: 50)
        #expect(slow.first == "kata-set-param maxVisits 1000000000")
        #expect(fast.first == "kata-set-param maxVisits 1000000000")
    }

    @MainActor
    @Test("the request fork: gen-move arms the rank budget, spectator paths re-arm unbounded")
    func requestAnalysisFork() {
        let gobanState = GobanState()
        let config = Config()
        config.whiteMaxTime = 0.5
        config.humanProfileForWhite = "3k"
        gobanState.analysisStatus = .run
        let genMove = gobanState.getRequestAnalysisCommands(
            config: config, nextColorForPlayCommand: .white)
        #expect(genMove.contains("kata-set-param maxVisits 40"))
        gobanState.suppressesGenMove = true
        let spectate = gobanState.getRequestAnalysisCommands(
            config: config, nextColorForPlayCommand: .white)
        #expect(spectate.first == "kata-set-param maxVisits 1000000000")
    }
}
```

Adjust the literal strings ONLY if the builder's actual spelling differs (e.g. underscore formatting of the unbounded constant) — the assertion intent (each bundle deliberately sets `maxVisits`) is the requirement. Then extend the existing broadcast gen-move test suite (`BroadcastGenMoveTests` in `KataGo iOSTests/`) with one assertion using its existing harness: the command batch of a licensed broadcast gen-move contains a `kata-set-param maxVisits` line — i.e. `#expect(sentCommands.contains { $0.hasPrefix("kata-set-param maxVisits") })` in an existing scenario that captures the sent commands. If the suite's fakes already assert full command arrays and this is implied, strengthen the closest assertion to name `maxVisits` explicitly rather than adding a redundant scenario.

- [ ] **Step 5: Run both suites**

```bash
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:"KataGo AnytimeTests/RankCommandRearmTests" \
  -only-testing:"KataGo AnytimeTests/TVPlayabilityTests" \
  -only-testing:"KataGo AnytimeTests/BroadcastGenMoveTests" 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **`, non-zero count.

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): playability classifier + rank-budget re-arm checklist tests"
```

---

### Task 5: TVNewGameForm — the pure New Game form model

All form state, validation, and Config application live in the shared package (the visionOS `Vision/` precedent) so the iOS-simulator unit target covers them; Task 8's tvOS screen is a thin shell over this.

**Files:**
- Create: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVNewGameForm.swift`
- Test: `ios/KataGo iOS/KataGo iOSTests/TVNewGameFormTests.swift` (register, anchor `TVPlayabilityTests.swift`)

**Interfaces:**
- Consumes: `BoardHandicapPoints` (Task 1), `GameRecord.makeSgf(...handicap:)` (Task 2), `NewGameRuleset.pickerCases/sgfToken/configRuleIndex/displayName`, `NewGameRules.expand/suggestedKomi` (`KataGoUICore/Model/NewGameRuleset.swift`), `HumanSLModel.allProfiles`, `Config.toggleAIThinkingTime`.
- Produces:

```swift
public struct TVNewGameForm: Equatable {
    public static let quickSizes: [Int]                 // [9, 13, 19]
    public static let rulesetChoices: [NewGameRuleset]  // the 11 named presets, no .custom
    public static let rankChoices: [String]             // HumanSLModel.allProfiles
    public static let handicapKomi: Float               // 0.5
    public private(set) var boardWidth: Int
    public private(set) var boardHeight: Int
    public var ruleset: NewGameRuleset                  // default .chinese
    public var rankProfile: String                      // default "AI"
    public private(set) var handicap: Int               // 0 or 2...9
    public var humanPlaysBlack: Bool                    // default true
    public let maxBoardLength: Int
    public init(maxBoardLength: Int)
    public var sizeCap: Int
    public func quickSizeEnabled(_ size: Int) -> Bool
    public mutating func setSize(width: Int, height: Int)
    public mutating func setHandicap(_ n: Int)
    public var availableHandicaps: [Int]
    public var handicapPickerEnabled: Bool
    public var komi: Float
    public var ruleString: String
    public var sgf: String?
    public var suggestedName: String
    @MainActor public func apply(to config: Config)
}
```

- [ ] **Step 1: Write the failing tests**

`KataGo iOSTests/TVNewGameFormTests.swift`:

```swift
import Testing
@testable import KataGoUICore
import KataGoGameStore

struct TVNewGameFormTests {
    @Test("init clamps the starting size to the launched buffer")
    func initClampsToBuffer() {
        #expect(TVNewGameForm(maxBoardLength: 37).boardWidth == 19)
        #expect(TVNewGameForm(maxBoardLength: 9).boardWidth == 9)
        #expect(TVNewGameForm(maxBoardLength: 9).boardHeight == 9)
    }

    @Test("quick sizes disable above the cap")
    func quickSizesRespectCap() {
        let form = TVNewGameForm(maxBoardLength: 13)
        #expect(form.quickSizeEnabled(9))
        #expect(form.quickSizeEnabled(13))
        #expect(!form.quickSizeEnabled(19))
    }

    @Test("setSize clamps to 2...cap")
    func setSizeClamps() {
        var form = TVNewGameForm(maxBoardLength: 19)
        form.setSize(width: 1, height: 40)
        #expect(form.boardWidth == 2)
        #expect(form.boardHeight == 19)
    }

    @Test("handicap availability follows the placement domain")
    func handicapAvailability() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setSize(width: 19, height: 19)
        #expect(form.availableHandicaps == [0, 2, 3, 4, 5, 6, 7, 8, 9])
        form.setSize(width: 13, height: 13)
        #expect(form.availableHandicaps == [0, 2, 3, 4, 5])
        form.setSize(width: 8, height: 8)
        #expect(form.availableHandicaps == [0])
        #expect(!form.handicapPickerEnabled)
    }

    @Test("shrinking the board clears a now-impossible handicap, keeps a valid one")
    func handicapClearsWhenSizeLosesLayout() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.setSize(width: 19, height: 19)
        form.setHandicap(9)
        form.setSize(width: 9, height: 9)
        #expect(form.handicap == 0)
        form.setHandicap(5)
        form.setSize(width: 13, height: 13)
        #expect(form.handicap == 5)
    }

    @Test("komi follows the preset until handicap forces 0.5")
    func komiFollowsPresetAndHandicap() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.ruleset = .japanese
        #expect(form.komi == 6.5)
        form.ruleset = .chinese
        #expect(form.komi == 7.5)
        form.ruleset = .agaButton
        #expect(form.komi == 7.0)
        form.setHandicap(2)
        #expect(form.komi == 0.5)
    }

    @Test("the SGF carries size, handicap, PL, komi, and the preset token")
    func sgfCarriesEverything() throws {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.ruleset = .japanese
        form.setHandicap(3)
        let sgf = try #require(form.sgf)
        #expect(sgf.contains("HA[3]"))
        #expect(sgf.contains("PL[W]"))
        #expect(sgf.contains("KM[0.5]"))
        #expect(sgf.contains("RU[japanese]"))
    }

    @Test("ruleset choices are the 11 named presets")
    func rulesetChoices() {
        #expect(TVNewGameForm.rulesetChoices.count == 11)
        #expect(!TVNewGameForm.rulesetChoices.contains(.custom))
    }

    @MainActor
    @Test("apply assigns the engine side, both directions")
    func applySetsTheEngineSide() {
        var form = TVNewGameForm(maxBoardLength: 37)
        form.rankProfile = "3k"
        form.ruleset = .japanese
        let config = Config()
        form.apply(to: config)
        #expect(config.blackMaxTime == 0)
        #expect(config.whiteMaxTime == Config.toggleAIThinkingTime)
        #expect(config.humanProfileForWhite == "3k")
        #expect(config.rule == NewGameRuleset.japanese.configRuleIndex)

        form.humanPlaysBlack = false
        let flipped = Config()
        form.apply(to: flipped)
        #expect(flipped.whiteMaxTime == 0)
        #expect(flipped.blackMaxTime == Config.toggleAIThinkingTime)
        #expect(flipped.humanProfileForBlack == "3k")
    }

    @Test("suggested name carries the rank")
    func suggestedName() {
        var form = TVNewGameForm(maxBoardLength: 37)
        #expect(form.suggestedName == "vs KataGo")
        form.rankProfile = "3k"
        #expect(form.suggestedName == "vs KataGo 3k")
    }
}
```

- [ ] **Step 2: Register the test file and run to verify failure** — Task 2 Step 6 snippet, anchor `TVPlayabilityTests.swift`, then the `-only-testing:"KataGo AnytimeTests/TVNewGameFormTests"` run. Expected: compile FAILURE.

- [ ] **Step 3: Implement TVNewGameForm**

`KataGoUICore/Sources/KataGoUICore/Util/TVNewGameForm.swift`:

```swift
import Foundation
import KataGoGameStore

/// Pure state + validation for the tvOS "Play KataGo" New Game form. Lives
/// in the shared package so the iOS-simulator unit target covers it; the
/// tvOS screen is a thin SwiftUI shell over this.
public struct TVNewGameForm: Equatable {
    public static let quickSizes = [9, 13, 19]
    /// The 11 named presets; the granular Custom editor stays iOS/macOS.
    public static let rulesetChoices: [NewGameRuleset] =
        NewGameRuleset.pickerCases.filter { $0 != .custom }
    public static let rankChoices = HumanSLModel.allProfiles
    /// Classic handicap compensation: stones instead of points.
    public static let handicapKomi: Float = 0.5

    public private(set) var boardWidth: Int
    public private(set) var boardHeight: Int
    public var ruleset: NewGameRuleset = .chinese
    public var rankProfile: String = "AI"
    public private(set) var handicap: Int = 0
    public var humanPlaysBlack: Bool = true
    /// The LAUNCHED NN buffer (engine.maxBoardLength) — never live settings.
    public let maxBoardLength: Int

    public init(maxBoardLength: Int) {
        self.maxBoardLength = maxBoardLength
        let initial = max(2, min(19, maxBoardLength))
        boardWidth = initial
        boardHeight = initial
    }

    public var sizeCap: Int { max(2, min(37, maxBoardLength)) }
    public func quickSizeEnabled(_ size: Int) -> Bool { size <= sizeCap }

    public mutating func setSize(width: Int, height: Int) {
        boardWidth = min(max(2, width), sizeCap)
        boardHeight = min(max(2, height), sizeCap)
        if handicap != 0, !availableHandicaps.contains(handicap) { handicap = 0 }
    }

    public mutating func setHandicap(_ n: Int) {
        handicap = availableHandicaps.contains(n) ? n : 0
    }

    /// 0 plus every n in 2...9 the board has a conventional layout for.
    public var availableHandicaps: [Int] {
        [0] + (2...9).filter {
            BoardHandicapPoints.points(width: boardWidth, height: boardHeight, count: $0).count == $0
        }
    }

    public var handicapPickerEnabled: Bool { availableHandicaps.count > 1 }

    /// Handicap forces komi 0.5; otherwise KataGo's own default for the preset.
    public var komi: Float {
        if handicap > 0 { return Self.handicapKomi }
        guard let components = NewGameRules.expand(ruleset) else { return 7.0 }
        return NewGameRules.suggestedKomi(components)
    }

    public var ruleString: String { ruleset.sgfToken ?? "chinese" }

    public var sgf: String? {
        GameRecord.makeSgf(width: boardWidth, height: boardHeight, komi: komi,
                           ruleString: ruleString, handicap: handicap)
    }

    public var suggestedName: String {
        rankProfile == "AI" ? "vs KataGo" : "vs KataGo \(rankProfile)"
    }

    /// KataGo's side gets the chosen rank + the standard 0.5 s thinking
    /// time; the human side gets maxTime 0 (the maxTime == 0 marker is what
    /// TVPlayability and the shared gen-move loop key off). Handicap stones
    /// are always Black's, so White + handicap is give-handicap play. The
    /// rule index must be set here: createGameRecord does not derive
    /// `Config.rule` from the SGF (the SelfPlaySeed factory documents that).
    @MainActor
    public func apply(to config: Config) {
        config.rule = ruleset.configRuleIndex
        if humanPlaysBlack {
            config.blackMaxTime = 0
            config.whiteMaxTime = Config.toggleAIThinkingTime
            config.humanProfileForWhite = rankProfile
        } else {
            config.whiteMaxTime = 0
            config.blackMaxTime = Config.toggleAIThinkingTime
            config.humanProfileForBlack = rankProfile
        }
    }
}
```

Note: `NewGameRules.expand` parses an `RU[]` probe through the C++ SGF parser — available on tvOS and in the test host; no engine loop involved.

- [ ] **Step 4: Run the tests** — same `-only-testing` run. Expected: `** TEST SUCCEEDED **`, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): New Game form model"
```

---

### Task 6: TVPlayScreen

The playable screen. It deliberately does NOT share state machinery with review (locked spectator) or self-play (broadcast protocol): `suppressesGenMove = false`, editing unlocked, and the move loop is entirely the existing shared turn observer — `BoardView` mounts on this screen, and its `.onChange(of: player.nextColorForPlayCommand)` hook (`BoardView.swift:234-247`) drives the asymmetric human-SL bundles and the gen-move for the side whose `maxTime > 0`. No new engine protocol.

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime TV/TVPlayScreen.swift` (register: `ruby scripts_add_swift_files.rb "KataGo Anytime TV" "KataGo Anytime TV/TVPlayScreen.swift"`)
- Read for patterns (do NOT modify): `TVReviewScreen.swift` (input stack, gate, panel), `TVSelfPlayScreen.swift` (result overlay), `VisionRootView.swift:555-575, 761-773` (`isAITurn`, `playPass`).

**Interfaces:**
- Consumes: `TVEngineController.maxBoardLength/phase`, `boardFits(width:height:maxBoardLength:)`, `GhostCursorModel`, `LastMoveKey`, `TVControllerInput.pushHandler/popHandler`, `tvSelectPress(isEnabled:perform:)`, `GobanState` (`loadGame`, `unlockEditingOnReload`, `sendCheckMoveCommand`, `backwardMoves`, `passCount`, `eyeStatus`, `analysisStatus`, `maybeRequestAnalysis`, `maybePauseAnalysis`, `isAnalysisOverlayVisible`), `SelfPlayGame.trailingPassCount(inSgf:)/result(fromSgf:)/resultText/anticipatedResultText`, `TVPlayerRow`, `TVScoreChart`, `TVBestMovesList`, `Config.playerLabel(for:)`.
- Produces: `struct TVPlayScreen: View { let game: GameRecord }` — Task 7 routes to it.

- [ ] **Step 1: Screen skeleton + gate + load**

Create `TVPlayScreen.swift`. Environments: mirror `TVReviewScreen.swift:36-49` (GobanState, Turn, BookLookup, MessageList, BoardSize, Stones, AudioModel, Winrate, Score, NavigationContext, Analysis, TVEngineController, TVControllerInput, `\.dismiss`). State: `didLoad`, `isAiming`, `@FocusState boardFocused`, `ghost = GhostCursorModel()`, `controllerToken = UUID()`, plus whatever review keeps for the wood-accent focus ring.

Body gate — copy review's shape (`TVReviewScreen.swift:109-140`) exactly, including `tooLargeView` (`ContentUnavailableView` + "Go Back" + `.onExitCommand { dismiss() }`; the too-large branch must never call `loadIfNeeded()`):

```swift
if let config = game.config,
   boardFits(width: config.boardWidth, height: config.boardHeight,
             maxBoardLength: engine.maxBoardLength) {
    playContent
} else {
    tooLargeView
}
```

`loadIfNeeded()` (called from `.onAppear` after `controllerInput.pushHandler(controllerToken) { handleControllerEvent($0) }`, mirroring review's `.onAppear` ordering at L333-335):

```swift
guard !didLoad else { return }
didLoad = true
gobanState.suppressesGenMove = false
gobanState.forcesBranchOnPlay = false
gobanState.suppressesHumanSLTurnCommands = false
// BEFORE load: the engine's play replies and printsgf echoes must land in
// THIS record (GameSession routes by navigationContext.selectedGameRecord).
navigationContext.selectedGameRecord = game
gobanState.passCount = SelfPlayGame.trailingPassCount(inSgf: game.sgf)
// One-shot: a game the user plays is theirs to edit; loadGame consumes it.
gobanState.unlockEditingOnReload = true
gobanState.loadGame(gameRecord: game, previous: nil, player: player,
                    bookLookup: bookLookup, messageList: messageList,
                    board: board, stones: stones)
// Ranked-play defaults: engine ON (gen-move requires .run), overlays OFF.
// eyeStatus closed + analysisStatus .run is the load-bearing pair: power
// saving then suppresses analyze on the human's turn while the engine's
// gen-move turns are unaffected. NEVER use .clear here — it kills the AI.
gobanState.analysisStatus = .run
gobanState.eyeStatus = .closed
```

Verify the exact `EyeStatus` closed-case name (`.opened`/`.book` are known; check the enum). After loadGame the showboard reply sets `player.nextColorForPlayCommand`, the turn observer fires, and — when resuming a game where it is the AI's turn — the engine moves immediately with no extra driver.

- [ ] **Step 2: Board + input stack**

Copy review's board modifier stack (`TVReviewScreen.swift:152-198`) minus the auto-play/timeline pieces: `BoardView(gameRecord: game, interactive: false, showsCapturedStones: false, showsPass: false, showsWinrateBar: false, cursorPoint: ghost.point, ...)` with `.focusable(true)`, `.focused($boardFocused)`, `.onMoveCommand(perform: boardMove)`, `.tvSelectPress(isEnabled: isAiming, perform: playAtCursor)`, the wood-accent focus ring, and the `boardFocused → isAiming + ghost.activate/reset` `.onChange`. Keep review's `LastMoveKey` anchor hook verbatim (`TVReviewScreen.swift:306-310, 555-559`) so the cursor reveals at the last move and re-anchors after undo. Copy review's ZStack geometry (board 1080×1080, panel ~500×1020, `.disabled(isAiming)` + `.focusSection()` on the panel). Default focus: the BOARD (`.defaultFocus($boardFocused, true)`) — playing is the primary action, and an accidental immediate Select is harmless because the anchor point is the last move, which is occupied and rejected by `playAtCursor`.

Move submission:

```swift
private func playAtCursor() {
    guard let point = ghost.point else { return }
    // Copy review's occupied-point rejection helper (TVReviewScreen playAtCursor, L740-747).
    guard !isOccupied(point) else { return }
    submit(vertex: point.gtpVertex(width: Int(board.width), height: Int(board.height)))
}

private func submit(vertex: String) {
    guard stones.isReady,
          gobanState.pendingMoveTurn == nil,        // single-flight
          !isAITurn,                                 // turn order: never on the engine's turn
          let turn = player.nextColorSymbolForPlayCommand else { return }
    gobanState.sendCheckMoveCommand(turn: turn, move: vertex, messageList: messageList)
}

/// Pure config check, copied from VisionRootView.isAITurn (L555+):
/// maxTime > 0 marks the engine's side; .unknown (engine not ready) counts
/// as AI so input is rejected until showboard lands.
private var isAITurn: Bool {
    let config = game.concreteConfig
    switch player.nextColorForPlayCommand {
    case .black: return config.blackMaxTime > 0
    case .white: return config.whiteMaxTime > 0
    default: return true
    }
}
```

Legality stays engine-side (`kata-check-move` reply handling in `GameSession` — nothing to add).

- [ ] **Step 3: Pass, undo, controller mapping, exit**

Pass — copy `VisionRootView.playPass` (L761-773) verbatim (guards: `nextColorSymbolForPlayCommand`, `stones.isReady`, `pendingMoveTurn == nil`, `!isAITurn`; audio click; `sendCheckMoveCommand(turn:move:"pass")` — a pass is always legal so the check round cannot retract it).

Undo — read VisionRootView's back-step controller handler first and copy its guard set; the core is:

```swift
private func undoOneMove() {
    guard stones.isReady, gobanState.pendingMoveTurn == nil else { return }
    gobanState.backwardMoves(limit: 1, gameRecord: game, messageList: messageList,
                             player: player, stones: stones)
}
```

Semantics (visionOS parity, spec-accepted): a single undo flips the turn to the engine, which replies; take-back is undo twice (hold L1 — `TVControllerInput.bindRepeating` already auto-repeats the shoulder while held). Because editing is unlocked and `forcesBranchOnPlay` is false, playing after an undo replaces the tail (the unlock-on-reload path), which is the intended play-mode behavior.

Controller events:

```swift
private func handleControllerEvent(_ event: TVControllerEvent) {
    switch event {
    case .buttonX: undoOneMove()
    case .buttonY: playPass()
    case .leftShoulder: undoOneMove()   // auto-repeats while held
    case .rightShoulder, .leftTrigger, .rightTrigger:
        return                          // unbound on the play screen (timeline nav is review's)
    }
}
```

Exit — `.onExitCommand` copies review's order (`TVReviewScreen.swift:315-330`): if `boardFocused` → `isAiming = false` + hop focus to the panel; else `dismiss()`. `.onDisappear`:

```swift
controllerInput.popHandler(controllerToken)
if navigationContext.selectedGameRecord === game { navigationContext.selectedGameRecord = nil }
gobanState.maybePauseAnalysis()
didLoad = false
```

(No `forcesBranchOnPlay` restore needed: every TV screen asserts its own flags on entry, and the library beneath has no board.)

- [ ] **Step 4: Panel + result overlay + analysis display toggle**

Panel (copy review's composition, `TVReviewScreen.swift:394-498`, dropping timeline/auto-play): title = `game.name`; `TVPlayerRow(isBlack:name:captures:)` for both sides with `name: config.playerLabel(for: .black/.white)` (this already renders "Human" for the maxTime == 0 side and the rank profile for the engine side) and review's captures source; the stats card (winrate headline, `Score ...`, "Move N — X to play", `TVScoreChart(gameRecord:currentIndex:)`) with review's eye-gated live-vs-persisted value switch; `TVBestMovesList` ONLY when the eye is open — gate any board overlay decision through `gobanState.isAnalysisOverlayVisible(config:...)`, never `analysisStatus` (eye = display, sparkle = engine); an info row (Move/Komi/Rules); a buttons row: Pass, Undo, and the analysis-display toggle; review's exit hint.

Analysis display toggle — eye-only, deliberately NOT review's `toggleAnalysis` (which flips `analysisStatus` and would stop the engine):

```swift
private func toggleAnalysisDisplay() {
    if gobanState.eyeStatus == .closed {
        gobanState.eyeStatus = .opened
        gobanState.maybeRequestAnalysis(config: game.concreteConfig,
                                        nextColorForPlayCommand: player.nextColorForPlayCommand,
                                        messageList: messageList)
    } else {
        gobanState.eyeStatus = .closed
        // Mid-human-turn a kata-analyze may be streaming; stop it. Never
        // send "stop" on the engine's turn — that cancels its move.
        if !isAITurn { messageList.appendAndSend(command: "stop") }
    }
}
```

Result overlay — gate on `gobanState.passCount >= 2` and copy `TVSelfPlayScreen`'s `interstitial`/`resultText` pattern (L523-550): `SelfPlayGame.result(fromSgf: game.sgf)` when parsed (the engine's post-pass printsgf embeds `RE[...]`), else `SelfPlayGame.anticipatedResultText(blackScore: rootScore.black)`. The gen-move loop stops by itself (`passCount < 2` guards in `shouldGenMove`/`getRequestAnalysisCommands`). The record persists; there is no resign (platform parity).

- [ ] **Step 5: Register, build, test**

```bash
cd "ios/KataGo iOS" && ruby scripts_add_swift_files.rb "KataGo Anytime TV" "KataGo Anytime TV/TVPlayScreen.swift"
cd "ios/KataGo iOS" && xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" \
  -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
cd "ios/KataGo iOS" && xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" \
  -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
```

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` (the screen is not routed yet — that is Task 7 — so the build is the gate here).

- [ ] **Step 6: Commit**

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): TVPlayScreen - play a human-vs-AI game with the controller"
```

---

### Task 7: Route playable records to TVPlayScreen + Continue badge + legend

**Files:**
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift:76-110` (both `GameRecord` navigation destinations)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVLibraryView.swift` (Continue badge on `TVGameCard`)
- Modify: `ios/KataGo iOS/KataGoUICore/Sources/KataGoUICore/Util/TVControllerEvent.swift` (legend `play` column)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVSettingsScreen.swift:206-231` (legend grid third column)
- Test: `ios/KataGo iOS/KataGo iOSTests/TVControllerLegendTests.swift` (existing — extend)

**Interfaces:**
- Consumes: `TVPlayability.isPlayable(_ record:)` (Task 4), `TVPlayScreen(game:)` (Task 6).
- Produces: `TVControllerLegendRow` gains `public let play: String`; `TVControllerLegend.rows` carries the play-screen column.

- [ ] **Step 1: Extend the legend type + failing test**

In `TVControllerLegendTests.swift`, add expectations for the new column (align assertion style with the file's existing tests):

```swift
@Test("play-screen column")
func playColumn() {
    let byEvent = Dictionary(uniqueKeysWithValues: TVControllerLegend.rows.map { ($0.event, $0.play) })
    #expect(byEvent[.buttonX] == "Undo")
    #expect(byEvent[.buttonY] == "Pass")
    #expect(byEvent[.leftShoulder] == "Undo (hold)")
    #expect(byEvent[.rightShoulder] == "—")
    #expect(byEvent[.leftTrigger] == "—")
    #expect(byEvent[.rightTrigger] == "—")
}
```

Run `-only-testing:"KataGo AnytimeTests/TVControllerLegendTests"` — expected: compile FAILURE (`play` missing). Then add `public let play: String` to `TVControllerLegendRow` (update its init and every row literal in `TVControllerLegend.rows` with the values above; keep the existing `review`/`live` strings byte-identical). Re-run — expected: PASS.

- [ ] **Step 2: Legend grid third column**

In `TVSettingsScreen.swift`'s legend `Grid` (L206-231): add a "Playing" header cell beside "Reviewing"/"Live" and `Text(row.play)` in each `GridRow`.

- [ ] **Step 3: Route classification**

In `TVRootView.swift`, both `navigationDestination(for: GameRecord.self)` closures (library L78-83, search L100-105) become:

```swift
.navigationDestination(for: GameRecord.self) { game in
    if TVPlayability.isPlayable(game) {
        TVPlayScreen(game: game)
            .toolbar(.hidden, for: .tabBar)
    } else {
        TVReviewScreen(game: game, onContinueLive: { seed in
            libraryPath.append(SelfPlayRoute(entry: .manual, seed: seed))   // searchPath in the search stack
        })
            .toolbar(.hidden, for: .tabBar)
    }
}
```

- [ ] **Step 4: Continue badge**

In `TVLibraryView.swift`, give `TVGameCard` a playable treatment: when `TVPlayability.isPlayable(game)`, show a "Continue" capsule badge styled like `TVSelfPlayCard`'s "Live" badge (read `TVSelfPlayCard`, `TVReviewScreen.swift:894-934` area, for the capsule styling). Apply wherever `TVGameCard` renders (library grid + search results) — prefer computing it inside `TVGameCard` so both call sites inherit it.

- [ ] **Step 5: Build + test + commit**

TV build, then the full unit suite (commands as in Task 6 Step 5); expected `** BUILD SUCCEEDED **` / `** TEST SUCCEEDED **`. Then:

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): route playable games to TVPlayScreen, Continue badge, legend column"
```

---

### Task 8: TVNewGameScreen + Play KataGo library card + creation flow

**Files:**
- Create: `ios/KataGo iOS/KataGo Anytime TV/TVNewGameScreen.swift` (register: `ruby scripts_add_swift_files.rb "KataGo Anytime TV" "KataGo Anytime TV/TVNewGameScreen.swift"`)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVLibraryView.swift` (lead card + empty-state card + focus case)
- Modify: `ios/KataGo iOS/KataGo Anytime TV/TVRootView.swift` (destination for `NewGameRoute` in the library stack)

**Interfaces:**
- Consumes: `TVNewGameForm` (Task 5), `GameRecord.createGameRecord(sgf:name:)`, `TVEngineController.maxBoardLength/phase`, `@Environment(\.modelContext)` (the shared CloudKit store — the TV app already mounts `SharedModelContainer.shared`).
- Produces: `struct NewGameRoute: Hashable {}` (TV target) and `struct TVNewGameScreen: View { let onStart: (GameRecord) -> Void }`.

- [ ] **Step 1: The screen**

`TVNewGameScreen.swift` — a thin shell over `TVNewGameForm`. tvOS has NO `Stepper`; every control is a `Picker` or `Button` (focus-engine native — no bare `.onTapGesture`). Match the section/typography style of `TVSettingsScreen`. Layout:

- **Board Size** — a row of quick buttons 9/13/19 (`.disabled(!form.quickSizeEnabled(size))`, highlighted when `form.boardWidth == size && form.boardHeight == size`) calling `form.setSize(width: size, height: size)`; below it Width/Height `Picker`s over `2...form.sizeCap` bound via:

```swift
Picker("Width", selection: Binding(
    get: { form.boardWidth },
    set: { form.setSize(width: $0, height: form.boardHeight) })) {
    ForEach(2...form.sizeCap, id: \.self) { Text("\($0)").tag($0) }
}
```

  and, when `form.sizeCap < 19`, the Vision-pattern hint footnote: `"Boards up to \(form.sizeCap)×\(form.sizeCap) with the current Max Board Size — raise it in the Settings tab for more."`
- **Ruleset** — `Picker` over `TVNewGameForm.rulesetChoices` (`displayName`).
- **KataGo Rank** — `Picker` over `TVNewGameForm.rankChoices` (a long pushed list is fine on tvOS).
- **Handicap** — `Picker` over `form.availableHandicaps` ("None" for 0, else "\(n) stones") bound through `form.setHandicap`, `.disabled(!form.handicapPickerEnabled)`; caption: "Handicap stones go to Black; komi becomes 0.5." and, when disabled, "This board size has no star-point layout for handicap stones."
- **Your Color** — `Picker` Black/White over `form.humanPlaysBlack`.
- **Start Game** — prominent button, `.disabled(form.sgf == nil || engine.phase != .running)`.

Form state: `@State private var form = TVNewGameForm(maxBoardLength: 19)` plus a `didSeed` flag; on appear, `form = TVNewGameForm(maxBoardLength: engine.maxBoardLength)` once (the environment engine is unavailable in `init`).

Start action:

```swift
private func startGame() {
    guard let sgf = form.sgf else { return }
    let record = GameRecord.createGameRecord(sgf: sgf, name: form.suggestedName)
    form.apply(to: record.concreteConfig)
    modelContext.insert(record)
    try? modelContext.save()
    onStart(record)
}
```

No `unlockEditingOnReload` here — `TVPlayScreen.loadIfNeeded` sets it on every load (unlike visionOS, where `startNewGame` must because its open path does not). No boardFits check needed at creation — the form caps at `engine.maxBoardLength` by construction, and `TVPlayScreen` re-gates on entry anyway.

- [ ] **Step 2: Library entry + routing**

In `TVLibraryView.swift`: add `struct NewGameRoute: Hashable {}` (or place it beside `SelfPlayRoute` in `TVSelfPlayScreen.swift` — follow the existing route-type location convention); a `TVPlayKataGoCard` styled like `TVSelfPlayCard` (title "Play KataGo", subtitle e.g. "Human vs KataGo — rank, rules, handicap"); a `NavigationLink(value: NewGameRoute()) { TVPlayKataGoCard() }.buttonStyle(.card)` beside the self-play card in the populated grid AND in the empty-state `sampleCards` HStack (the Play card is not gated on `TVSampleGameStore.isAvailable` — it needs no sample store); a new `LibraryFocus` case for it.

In `TVRootView.swift`, library stack only:

```swift
.navigationDestination(for: NewGameRoute.self) { _ in
    TVNewGameScreen(onStart: { record in
        libraryPath.removeLast()      // replace the form with the game
        libraryPath.append(record)    // classifier routes it to TVPlayScreen
    })
    .toolbar(.hidden, for: .tabBar)
}
```

- [ ] **Step 3: Register, build, test, commit**

```bash
cd "ios/KataGo iOS" && ruby scripts_add_swift_files.rb "KataGo Anytime TV" "KataGo Anytime TV/TVNewGameScreen.swift"
```

TV build + full unit suite (commands as in Task 6 Step 5); expected green. Then:

```bash
git add -A "ios/KataGo iOS"
git commit -m "feat(tv): New Game screen - start a customized game against KataGo"
```

---

### Task 9: Docs + full verification sweep + device gates

**Files:**
- Modify: `README.md` (tvOS feature bullets)
- Modify: `CLAUDE.md` (only if its tvOS description contradicts the new capability)

- [ ] **Step 1: Docs**

Update the README's tvOS section: playing against KataGo at certified human-SL ranks, the New Game form (size/ruleset/rank/handicap/color), Continue for synced human-vs-AI games, and that TV-created games sync via iCloud. Verify every claim against the source just written — never against prior README text. Check `CLAUDE.md`'s tvOS mentions for stale "watch-only/spectate-only" phrasing and correct only what is now wrong.

- [ ] **Step 2: Full verification sweep** (run by the controller session, sequentially — NEVER two xcodebuild jobs at once, never delegated to a subagent)

```bash
cd "ios/KataGo iOS"
xcodebuild test -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"
(cd KataGoUICore && swift test 2>&1 | tail -3)
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime" -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Mac" -destination 'platform=macOS' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Vision" -destination 'platform=visionOS Simulator,name=Apple Vision Pro' -configuration Debug 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime TV" -destination 'platform=tvOS Simulator,name=Apple TV' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
xcodebuild build -project "KataGo Anytime.xcodeproj" -scheme "KataGo Anytime Watch" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)"
```

Expected: `** TEST SUCCEEDED **` (unit + both package suites) and five `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit docs**

```bash
git add README.md CLAUDE.md
git commit -m "docs: tvOS play-vs-KataGo feature notes"
```

- [ ] **Step 4: Device gates (the user's hardware — report, do not attempt on the simulator)**

> **Correction, 2026-08-14: this gate PASSED on device.** Both nets stay
> resident; the conditional-restart fallback below was never built and is not
> needed. The original text is kept as written.

**BLOCKING ship gate — dual-net memory validation on Apple TV 4K (A12):** a full 19×19 ranked game plus a review broadcast with both nets resident, judged by vmmap "Physical footprint (peak)" with headroom against the ~2.1 GB budget (reference: two b18-class nets ≈ 1.2 GB on iPad, but tvOS runs a different shape — single CoreML server thread `[100]`, batch 2, `.cpuAndGPU`). If it FAILS: implement the designed fallback before shipping — `TVEngineController.restartEngine` grows an include-human-net parameter and the app keeps the human net resident only around ranked play (the proven Max-Board-Size restart pattern; never two engines at once).

**Manual QA checklist (Apple TV):**
1. Full ranked game at 19×19 (e.g. 5k): AI replies at rank strength; two passes end the game with a result overlay; the record persists.
2. Handicap-5 game: opening position correct, White moves first, komi 0.5 shown.
3. Give-handicap: play White + handicap 2 — KataGo's Black gets the stones, human (White) moves first.
4. Relaunch mid-game → the game shows Continue and resumes in TVPlayScreen with the AI responsive.
5. Continue an iPhone-started human-vs-AI game on the TV.
6. Sync round-trip: a TV-created game appears on iPhone (and its watch board renders the handicap stones).
7. First launch after install: double CoreML compile surfaced by the loading status; app remains responsive.
8. Thermal behavior over a long ranked game.
9. Siri-Remote-only play (no game controller): aim, play, pass (panel button), undo (panel button).
10. Review/self-play regression: a finished synced game still opens the locked review; KataGo-vs-KataGo still runs; narrated auto-play unaffected.

---

## Execution notes

- Tasks 1→2 and 4→5 are ordered dependencies; Task 3 is independent of 1-2 but must precede on-device ranked play; Tasks 6→7→8 build on 4-5.
- The dual-net fallback (conditional engine restart) is deliberately NOT a task — it is built only if the Task 9 device gate fails.
- Accepted residuals per spec: single-step undo hands the turn to the engine (visionOS parity); playable records cannot be opened in the locked review while unfinished.
