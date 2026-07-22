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
komi 7.5**. The player to move **wins the game if and only if they play the
biggest endgame moves in the correct order.** The intended play-out is:

1. From the start position, the human (the side to move) and the opponent
   alternate moves.
2. Play continues until **both sides pass**.
3. The result is scored by area. **Win = the side to move wins the game
   (correct); Fail = they lose (a mistake was made).**

Every mistake, against best opposition, flips the razor-thin result (±0.5 / ±1.5)
into a loss — this is checked exhaustively at generation time.

## API

```python
from katago.puzzles import (
    Difficulty, generate_endgame_puzzle, generate_endgame_sgf, best_endgame_moves,
)

sgf = generate_endgame_sgf(Difficulty.MEDIUM, seed=42)   # -> SGF string

puzzle = generate_endgame_puzzle(Difficulty.HARD, seed=7)
puzzle.sgf               # SGF-formatted text
puzzle.side_to_move      # Board.BLACK or Board.WHITE (the human)
puzzle.best_first_moves  # e.g. ["E5"] (GTP coordinates)
puzzle.optimal_score     # final black-area - white-area including komi
```

Same `(difficulty, seed)` always yields the identical puzzle.

### Using the module as an algorithm-only opponent / grader

Because the module is embedded in the app, the app can play the *punishing* line
and grade the human without any neural net:

```python
from katago.puzzles.endgame import best_endgame_moves
value, moves = best_endgame_moves(board, to_move)   # optimal margin + best move(s)
```

## Difficulty

Distinct gadget values on a 9×9 board are limited to `{2, 3, 4}` (a chain may not
span a frame's full width, or it would split the frame), so difficulty scales by
the number of contested moves and how much *defence* the player must read:

| Difficulty  | Contested moves | Character                                            |
|-------------|-----------------|------------------------------------------------------|
| `VERY_EASY` | 2 (values far)  | one obviously-biggest capture                        |
| `EASY`      | 2               | two captures to compare                              |
| `MEDIUM`    | 3               | order three captures                                 |
| `HARD`      | 3 (mixed)       | must value **defending** own groups, not just capturing |
| `VERY_HARD` | 3 (mixed)       | the single biggest move is a **defence** of own group |

## How it works

The contested regions are independent **capture-or-connect gadgets**: a chain of
`k` stones enclosed on three sides with one shared liberty `q` (the "door") that
also touches that colour's living wall. Whoever plays `q` first wins the gadget's
`k + 1` points for their colour — the enemy captures the chain, the owner
connects it to safety. Distinct chain sizes give distinct move values, so the
game is a race to take the biggest door first.

Generation constructs a candidate (two provably-alive framed groups + gadgets),
solves it exactly by confined minimax, tunes the score baseline to a razor
margin, and emits it **only if**: there is a unique biggest move, the side to move
wins by the minimal decisive margin, and every other first move loses. Frames are
verified to be single connected groups with two real eyes (unconditionally
alive), and the doors are verified to be the only contested points (so solving
over the doors equals the full legal-move game).

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
python genendgamepuzzles.py --difficulty medium --seed 42
python genendgamepuzzles.py -d hard -s 7 --show          # also prints the board
python genendgamepuzzles.py -d 1 -s 0 --count 5          # five puzzles
```

## Tests

From the `python/` directory: `pytest tests/test_endgame_puzzles.py`.
