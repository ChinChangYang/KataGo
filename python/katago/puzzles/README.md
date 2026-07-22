# 9×9 endgame puzzles

`katago.puzzles` generates 9×9 Go **endgame ("yose") puzzles** as **SGF-formatted
text**, deterministically from an integer `(difficulty, seed)`. Built for the
**KataGo Anytime** iOS app.

## Real-game "win by 0.5" puzzles (current generator)

Each puzzle is a **mostly-settled position from a real 9×9 KataGo self-play game**
(random / high-temperature opening for variety, then strong play into a rich real
endgame), served as a sharp quiz:

> **Black to play and win by exactly 0.5 — but only if you find the right move.**

Every puzzle is **Black to play**. Each has a **per-puzzle komi** set so that best
play wins by exactly **Black+0.5**, while the **natural (most tempting) move loses**.
The exact best-play margin is the game's own settled final area score; the amount
the natural move loses is KataGo's per-move estimate. The app plays the position out
to two passes and grades it with KataGo ("score by AI"). Because the positions come
from real games, they are genuine, varied yose — including tesuji where the natural
move is a trap.

```python
from katago.puzzles import generate_endgame_puzzle, generate_endgame_sgf

sgf = generate_endgame_sgf(difficulty=500, seed=42)   # difficulty is an int 1..999

p = generate_endgame_puzzle(difficulty=999, seed=7)
p.sgf               # SGF text (SZ[9] KM[<per-puzzle>] RU[TrompTaylor] PL[B] AB/AW + comment)
p.side_to_move      # always Board.BLACK
p.best_first_moves  # KataGo's winning move, e.g. ["C7"]
p.optimal_score     # 0.5  (Black wins by exactly 0.5 with best play)
p.difficulty        # 1..999
p.natural_move      # the tempting move that loses
p.natural_cost      # points the natural move loses (>= 1)
```

`difficulty` is an **integer in `[1, 999]`** (1 easiest, 999 hardest), clamped. Same
`(difficulty, seed)` always yields the identical puzzle. The generator is a pure,
deterministic **selector over a committed corpus** (`games/puzzles.json`) — no
neural net is needed at runtime.

### How difficulty is calibrated

Every endgame decision in the game corpus is scored by how **non-obvious KataGo's
best move is** (low policy prior → the net itself didn't favour it, search found
it), whether the **natural move is a costly trap**, and **board complexity**. Scores
are ranked across the whole corpus and mapped to `1..999` by percentile, so 999 is
the hardest yose the corpus contains and the scale is grounded in real play.

### Regenerating / growing the corpus

The corpus is produced offline by the pipeline in [`tools/`](tools/README.md): build
KataGo (CPU/Eigen, using a net that ships in `cpp/tests/models/`), self-play a batch
of games, then extract and calibrate puzzles. Re-run with more games (or a stronger
net) to add variety.

## Command line

```
python genendgamepuzzles.py --difficulty 500 --seed 42
python genendgamepuzzles.py -d 999 -s 7 --show           # also prints the board + answer
python genendgamepuzzles.py -d hard -s 0 --count 5       # names also map to integers
```

## SGF format

Single line, KataGo-compatible:
`(;FF[4]GM[1]SZ[9]PB[Black]PW[White]HA[0]KM[<per-puzzle>]RU[TrompTaylor]PL[B]AB[…]AW[…]C[…])`
— `AB`/`AW` setup stones (SGF letters, top-origin), `PL[B]` (always Black to move),
a **per-puzzle `KM`** (half-integer, tuned so best play wins by 0.5), and a comment
with KataGo's winning move and the losing natural move. No `RE` (not yet played).

## Also included: a self-contained constructed generator

`katago.puzzles.endgame` is an earlier, fully **self-contained** generator that
*constructs* positions and *certifies* them with an exact minimax solver (no neural
net at all). It is capped in difficulty by what small constructed shapes can express,
which is why the real-game generator above superseded it; its helpers (`area_score`,
`to_sgf`, `EndgameSolver`) are reused here. See its docstring for details.

## Tests

From the `python/` directory: `pytest tests/`.
