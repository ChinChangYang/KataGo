# Algorithm-only 9×9 endgame puzzles

`katago.puzzles.endgame` generates 9×9 Go **endgame ("biggest move") puzzles**
deterministically from a `(difficulty, seed)` pair and emits them as
**SGF-formatted text**. No neural net is involved — every puzzle is *constructed*
and then *certified correct by exact minimax search*, so the guarantees below are
proven, not estimated.

Built for the **KataGo Anytime** iOS app, but the module is pure Python with a
single dependency on `katago.game.board`.

## The puzzle

A puzzle is a settled 9×9 position, area-scored under **Tromp-Taylor rules with
komi 7.5**. The player to move **wins the game if and only if they find the
correct endgame play.** The intended play-out is:

1. From the start position, the human (the side to move) and the opponent
   alternate moves.
2. Play continues until **both sides pass**.
3. The result is scored by area. **Win = the side to move wins the game
   (correct); Fail = they lose (a mistake was made).**

Every suboptimal move, against best opposition, flips the razor-thin result
(±0.5 / ±1.5) into a loss — this is checked exhaustively at generation time.

## API

```python
from katago.puzzles import generate_endgame_puzzle, generate_endgame_sgf, best_endgame_moves

sgf = generate_endgame_sgf(difficulty=500, seed=42)   # difficulty is an int 1..999

puzzle = generate_endgame_puzzle(difficulty=999, seed=7)
puzzle.sgf               # SGF-formatted text
puzzle.side_to_move      # Board.BLACK or Board.WHITE (the human)
puzzle.best_first_moves  # winning first move(s), GTP coords e.g. ["E5"]
puzzle.optimal_score     # final black-area - white-area including komi
puzzle.difficulty        # the requested difficulty (1..999)
puzzle.complexity        # measured structural difficulty (regions, traps, ...)
```

`difficulty` is an **integer in `[1, 999]`** (1 easiest, 999 hardest), clamped to
that range. The `Difficulty` enum still exists as convenience anchors
(`VERY_EASY = 1`, `EASY = 250`, `MEDIUM = 500`, `HARD = 750`, `VERY_HARD = 999`),
and its members are plain ints, so `generate_endgame_puzzle(Difficulty.HARD, 7)`
also works. Same `(difficulty, seed)` always yields the identical puzzle.

### Using the module as an algorithm-only opponent / grader

Because the module is embedded in the app, the app can play the *punishing* line
and grade the human without any neural net:

```python
from katago.puzzles.endgame import best_endgame_moves
value, moves = best_endgame_moves(board, to_move)   # optimal margin + best move(s)
```

## Difficulty

Difficulty is calibrated to **max out the 9×9 board under area scoring** — a small
board has a real ceiling on independent endgame regions. The integer scale drives:

- **More regions** — 2 (easy) up to 3 independent local endgames to handle.
- **Reading traps** — up to 2 *reading gadgets* where the natural atari fails and
  only the connection-denying move captures, so choosing the move takes reading,
  not just comparing sizes.
- **Closeness** — near-equal region values, so the win hinges on counting and
  parity (tedomari) instead of an obvious biggest point.

Roughly: `1–249` are simple 2-region "biggest capture" puzzles; `250–666` add a
reading trap and a third region; `667–999` add a second reading trap and tighten
the values. The top of the range saturates structurally (the accepted 9×9
ceiling) and differs by counting subtlety, which the `complexity` field records.

**A note on sente.** Classic *sente* is inherently weak under **area** scoring —
a defensive connection into one's own area is free, so a "forcing" move gains
nothing and does not have to be answered. The harder puzzles here therefore get
their difficulty from **reading and counting** rather than sente. True
sente/gote/reverse-sente yose would require **territory** scoring.

## How it works

The contested regions are independent **capture-or-connect gadgets**: a chain of
`k` stones enclosed on three sides, touching that colour's living wall through a
single door `q`. Whoever plays `q` first wins the gadget's `k + 1` points — the
enemy captures the chain, the owner connects it to safety. A **reading gadget**
gives the chain a *second, outside liberty*: capturing then requires playing the
door (denying the connection) first; the natural atari from the outside lets the
chain connect out and fails. That turns "compare the sizes" into "read the
capture".

Generation constructs a candidate (two provably-alive framed groups + gadgets),
solves it exactly by confined minimax, tunes the score baseline to a razor
margin, and emits it **only if** the side to move wins by the minimal decisive
margin and **every non-optimal first move loses** (so any mistake — wrong
reading, wrong region, wrong order — loses the game). Frames are verified to be
single connected groups with two real eyes (unconditionally alive), and the
gadget cells are verified to be the only contested points (so solving over them
equals the full legal-move game).

The minimax is memoised on the **exact board contents** plus side-to-move, pass
count, and ko point — keying on the board's incremental Zobrist hash is unsafe
here (it can drift after capture sequences and silently corrupt the search).

## SGF format

Single line, KataGo-compatible, e.g.:

```
(;FF[4]GM[1]SZ[9]PB[Black]PW[White]HA[0]KM[7.5]RU[TrompTaylor]PL[B]AB[...]AW[...]C[Black to play. ...])
```

* `SZ[9]`, `HA[0]`, `KM[7.5]`, `RU[TrompTaylor]`.
* `AB`/`AW` setup stones; SGF letters are top-origin (`x → column`, `y → row`,
  `x = 0 → 'a'`).
* `PL[B]`/`PL[W]` gives the side to move (a setup position needs it).
* No `RE` — the game hasn't been played; the intended result is in the `C[]`
  comment along with the best first move.

## Command line

```
python genendgamepuzzles.py --difficulty 500 --seed 42
python genendgamepuzzles.py -d 999 -s 7 --show           # also prints the board
python genendgamepuzzles.py -d medium -s 0 --count 5     # names also work
```

## Tests

From the `python/` directory: `pytest tests/test_endgame_puzzles.py`.
