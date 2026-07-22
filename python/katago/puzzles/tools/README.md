# Endgame-puzzle corpus pipeline (offline)

These tools generate the committed puzzle corpus
(`../games/puzzles.json`) from real KataGo self-play games. They are **offline**
and require a built `katago` binary + a neural-net model. The runtime generator
(`katago.puzzles.realgame`) only reads the finished `puzzles.json` — **no neural
net is needed at runtime**.

## 1. Build KataGo (CPU / Eigen)

A 9x9-capable net already ships in `cpp/tests/models/`, so no model download is
needed.

```bash
apt-get install -y libeigen3-dev libzip-dev
cd cpp
cmake -S . -B build -DUSE_BACKEND=EIGEN -DUSE_AVX2=1 -DNO_GIT_REVISION=1
cmake --build build -j"$(nproc)"          # produces cpp/build/katago
```

## 2. Generate a corpus of games

Plays varied 9x9 games (random/high-temperature opening for variety, KataGo's best
move thereafter) and records per-ply endgame analysis (scoreLead, policy priors,
ownership) to one JSON per game.

```bash
cd python
python -m katago.puzzles.tools.gen_games \
  --katago ../cpp/build/katago \
  --model  ../cpp/tests/models/g170e-b10c128-s1141046784-d204142634.bin.gz \
  --config ../cpp/configs/analysis_example.cfg \
  --out /tmp/games --start 0 --num 30
```

(~1 s/move on CPU; a full game is ~1 minute.)

## 3. Extract + calibrate puzzles

Selects endgame positions (mostly-settled board, a genuine decision where the
natural move is a costly trap), makes each **Black to play** (colour-flipping if
needed) with a **per-puzzle komi** so best play wins by exactly Black+0.5, scores
difficulty by how non-obvious KataGo's best move is (low policy prior), the trap's
temptation/cost, and board complexity, then maps to `1..999` by percentile.

```bash
python -m katago.puzzles.tools.build_corpus \
  --games /tmp/games --out katago/puzzles/games/puzzles.json
```

Commit the resulting `puzzles.json`. Re-run steps 2–3 with more games (or a
stronger net / higher visits) to grow variety and refine the difficulty scale.

## Grading in the app

Each puzzle is Black to play with a komi tuned so best play wins by exactly 0.5.
The app plays the position out to two passes and grades it with its own KataGo
("score by AI"): the player is correct only if Black still wins by 0.5 — the
tempting natural move loses.
