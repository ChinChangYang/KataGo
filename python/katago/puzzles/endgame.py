"""Algorithm-only 9x9 endgame ("biggest move") puzzle generator.

No neural net is involved.  A puzzle is a settled 9x9 position, area-scored under
Tromp-Taylor rules with komi 7.5, in which the side to move wins the game if and
only if they find the correct endgame play; any suboptimal move, against best
opposition, flips the razor-thin result into a loss.  Correctness is *certified
at generation time* by exact minimax search over the small set of contested
points, so the generator never guesses.

Difficulty is an integer in ``[1, 999]`` (1 easiest, 999 hardest), calibrated to
what is achievable on a 9x9 board under area scoring.  It scales three ways:

* **More regions** -- more independent local endgames to handle and order.
* **Reading traps** -- capture "gadgets" where the natural atari fails and only
  the connection-denying move works, so choosing the move requires reading, not
  just comparing sizes.
* **Close values** -- regions of near-equal value, so the win hinges on counting
  and parity (tedomari) rather than an obvious biggest point.

(Note: classic *sente* is inherently weak under area scoring -- a defensive
connection into one's own area is free -- so the harder puzzles here get their
difficulty from reading and counting instead.  Territory scoring would be needed
for true sente/gote yose.)

The contested regions are independent "capture-or-connect" gadgets.  A gadget is
a chain of ``k`` stones enclosed on three sides, touching that colour's living
wall through a single door ``q``; whoever plays ``q`` first wins the gadget's
``k + 1`` points (the enemy captures the chain, the owner connects it to safety).
A *reading* gadget gives the chain a second, outside liberty: capturing then
requires playing the door (denying the connection) first -- the natural atari
from the outside lets the chain connect out and fails.

Public API
----------
``generate_endgame_puzzle(difficulty, seed) -> EndgamePuzzle``
``generate_endgame_sgf(difficulty, seed) -> str``
``best_endgame_moves(board, to_move) -> (value, [loc, ...])``
``area_score(board) -> (black_area, white_area)``
"""

from __future__ import annotations

import enum
import random
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Set, Tuple

from katago.game.board import Board

KOMI = 7.5
SIZE = 9
WCOL = 5  # boundary: Black frame is columns 0..4, White frame is columns 5..8.
DIFFICULTY_MIN = 1
DIFFICULTY_MAX = 999

# SGF point letters: index 0->'a' .. 25->'z', 26->'A' ..  (top-origin, column x
# then row y), identical to KataGo's WriteSgf::writeSgfLoc encoding.
_SGF_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


# --------------------------------------------------------------------------- #
# Scoring: Tromp-Taylor area scoring.
# --------------------------------------------------------------------------- #
def area_score(board: Board) -> Tuple[int, int]:
    """Return ``(black_area, white_area)`` under Tromp-Taylor area scoring."""
    black = 0
    white = 0
    visited: Set[int] = set()
    for y in range(board.y_size):
        for x in range(board.x_size):
            loc = board.loc(x, y)
            c = int(board.board[loc])
            if c == Board.BLACK:
                black += 1
            elif c == Board.WHITE:
                white += 1
            else:  # EMPTY
                if loc in visited:
                    continue
                region = [loc]
                visited.add(loc)
                borders: Set[int] = set()
                stack = [loc]
                while stack:
                    cur = stack.pop()
                    for d in board.adj:
                        adj = cur + d
                        ac = int(board.board[adj])
                        if ac == Board.EMPTY:
                            if adj not in visited:
                                visited.add(adj)
                                region.append(adj)
                                stack.append(adj)
                        elif ac == Board.BLACK or ac == Board.WHITE:
                            borders.add(ac)
                if borders == {Board.BLACK}:
                    black += len(region)
                elif borders == {Board.WHITE}:
                    white += len(region)
    return black, white


def score_black_minus_white(board: Board) -> int:
    b, w = area_score(board)
    return b - w


def _fmt(v: float) -> str:
    return ("%f" % v).rstrip("0").rstrip(".")


def result_string(black_minus_white_minus_komi: float) -> str:
    """SGF-style RE string from (black_area - white_area - komi)."""
    v = black_minus_white_minus_komi
    if v > 0:
        return "B+%s" % _fmt(v)
    if v < 0:
        return "W+%s" % _fmt(-v)
    return "0"


# --------------------------------------------------------------------------- #
# Exact endgame solver (confined minimax).
# --------------------------------------------------------------------------- #
class EndgameSolver:
    """Exact minimax over a confined set of contested points.

    Moves are restricted to ``contested`` locations (plus pass).  The rest of the
    board is settled/alive, so no other move is ever beneficial; this keeps the
    search tiny and exact.  Leaf value (after two consecutive passes) is the
    Tromp-Taylor area score ``black - white``.  Black maximises it, White
    minimises it.
    """

    def __init__(self, contested: Sequence[int]):
        self.contested: List[int] = list(contested)
        self._memo: Dict[Tuple[int, int, int], int] = {}

    def _candidates(self, board: Board, to_move: int) -> List[int]:
        return [
            loc
            for loc in self.contested
            if int(board.board[loc]) == Board.EMPTY and board.would_be_legal(to_move, loc)
        ]

    def _value(self, board: Board, to_move: int, passes: int) -> int:
        if passes >= 2:
            return score_black_minus_white(board)
        # Key on the exact board contents (not the incremental Zobrist hash, which
        # can drift out of sync with the board after capture sequences) plus the
        # side to move, pass count, and ko point (which changes legal moves).
        key = (board.board.tobytes(), to_move, passes, board.simple_ko_point)
        cached = self._memo.get(key)
        if cached is not None:
            return cached

        opp = Board.get_opp(to_move)
        maximizing = to_move == Board.BLACK
        best: Optional[int] = None
        # Copy per node so the Zobrist hash stays exact and memoisation collapses
        # transpositions (the reachable state space is small once memoised).
        for loc in self._candidates(board, to_move):
            child = board.copy()
            child.play(to_move, loc)
            v = self._value(child, opp, 0)
            if best is None or (v > best if maximizing else v < best):
                best = v
        child = board.copy()
        child.play(to_move, Board.PASS_LOC)
        v = self._value(child, opp, passes + 1)
        if best is None or (v > best if maximizing else v < best):
            best = v

        self._memo[key] = best
        return best

    def evaluate_root(self, board: Board, to_move: int) -> Dict[int, int]:
        """Value (``black - white`` at game end) of each legal first move."""
        opp = Board.get_opp(to_move)
        results: Dict[int, int] = {}
        for loc in self._candidates(board, to_move):
            child = board.copy()
            child.play(to_move, loc)
            results[loc] = self._value(child, opp, 0)
        return results

    def solve(self, board: Board, to_move: int) -> Tuple[int, List[int]]:
        """Return ``(optimal_black_minus_white, best_first_move_locs)``."""
        results = self.evaluate_root(board, to_move)
        if not results:
            return score_black_minus_white(board), []
        best = max(results.values()) if to_move == Board.BLACK else min(results.values())
        best_moves = sorted(loc for loc, v in results.items() if v == best)
        return best, best_moves


def empty_points(board: Board) -> List[int]:
    """Every empty on-board point (the full set of legal endgame moves here)."""
    return [
        board.loc(x, y)
        for y in range(board.y_size)
        for x in range(board.x_size)
        if int(board.board[board.loc(x, y)]) == Board.EMPTY
    ]


def best_endgame_moves(board: Board, to_move: int) -> Tuple[float, List[int]]:
    """Public helper: optimal final margin (``black - white`` incl. komi) and the
    optimal move location(s) for ``to_move`` in a settled endgame position.
    Intended for an app to use this module as an algorithm-only opponent/grader.
    """
    solver = EndgameSolver(empty_points(board))
    value, moves = solver.solve(board, to_move)
    return value - KOMI, moves


# --------------------------------------------------------------------------- #
# SGF writing (KataGo-compatible, single line).
# --------------------------------------------------------------------------- #
def sgf_point(x: int, y: int) -> str:
    return _SGF_CHARS[x] + _SGF_CHARS[y]


def _sgf_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("]", "\\]")


def to_sgf(
    board: Board,
    side_to_move: int,
    comment: str,
    komi: float = KOMI,
    black_name: str = "Black",
    white_name: str = "White",
) -> str:
    """Serialise a setup position to a single-line SGF string (with ``PL``)."""
    ab: List[str] = []
    aw: List[str] = []
    for y in range(board.y_size):
        for x in range(board.x_size):
            c = int(board.board[board.loc(x, y)])
            if c == Board.BLACK:
                ab.append(sgf_point(x, y))
            elif c == Board.WHITE:
                aw.append(sgf_point(x, y))

    parts = [
        "(;FF[4]GM[1]",
        "SZ[%d]" % board.x_size
        if board.x_size == board.y_size
        else "SZ[%d:%d]" % (board.x_size, board.y_size),
        "PB[%s]" % black_name,
        "PW[%s]" % white_name,
        "HA[0]",
        "KM[%s]" % _fmt(komi),
        "RU[TrompTaylor]",
        "PL[%s]" % ("B" if side_to_move == Board.BLACK else "W"),
    ]
    if ab:
        parts.append("AB" + "".join("[%s]" % p for p in ab))
    if aw:
        parts.append("AW" + "".join("[%s]" % p for p in aw))
    parts.append("C[%s]" % _sgf_escape(comment))
    parts.append(")")
    return "".join(parts)


# --------------------------------------------------------------------------- #
# Difficulty (integer 1..999) + schedule.
# --------------------------------------------------------------------------- #
class Difficulty(enum.IntEnum):
    """Convenience anchors; any integer in [1, 999] is accepted as difficulty."""

    VERY_EASY = 1
    EASY = 250
    MEDIUM = 500
    HARD = 750
    VERY_HARD = 999


@dataclass
class _Schedule:
    n_regions: int   # number of contested gadgets (2..4 on 9x9)
    n_traps: int     # reading-trap gadgets (0..2), attacked by the side to move
    closeness: float # 0 -> wide value gaps, 1 -> near-equal values


def _schedule(difficulty: int) -> _Schedule:
    """Map an integer difficulty to construction knobs (monotone in difficulty).

    The 9x9 board caps structural complexity, so 999 tops out at ~4 regions with
    2 reading traps and near-equal values; higher difficulty within a tier tightens
    the counting rather than adding regions.
    """
    d = max(DIFFICULTY_MIN, min(DIFFICULTY_MAX, int(difficulty)))
    t = (d - 1) / (DIFFICULTY_MAX - 1)                       # 0..1
    n = 2 if t < 1.0 / 3.0 else 3                            # 2 or 3 regions
    n_traps = 0 if t < 0.25 else (1 if t < 2.0 / 3.0 else 2)  # 0, 1, 2 reading traps
    n_traps = min(n_traps, n - 1)                            # keep >=1 gote region
    return _Schedule(n_regions=n, n_traps=n_traps, closeness=t)


# --------------------------------------------------------------------------- #
# Gadgets.
# --------------------------------------------------------------------------- #
GOTE = "gote"        # 1-liberty chain: door is the capture point.
READING = "reading"  # 2-liberty chain: door captures, outside approach is a trap.

# A gadget is (row, size, chain_color, kind).  chain_color WHITE = a White chain in
# Black's area (attacked/captured by Black); BLACK is the mirror in White's area.
Gadget = Tuple[int, int, int, str]

# Size limits so a chain never spans a frame's full width (which would split the
# frame into two one-eyed groups).  A reading gadget needs an extra approach column.
_GOTE_MAX = {Board.WHITE: WCOL - 2, Board.BLACK: SIZE - WCOL - 2}        # {W:3, B:2}
_READING_MAX = {Board.WHITE: WCOL - 3, Board.BLACK: SIZE - WCOL - 3}     # {W:2, B:1}


@dataclass
class _GadgetInfo:
    door: int
    approach: Optional[int]   # reading only
    probe: int                # a chain stone
    size: int
    chain_color: int
    kind: str


@dataclass
class _Built:
    board: Board
    contested: List[int]          # all gadget cells (doors + approaches)
    gadgets: List[_GadgetInfo]
    side_to_move: int


def _gadget_geometry(gadget: Gadget):
    """Return (door_x, chain_xs, approach_x_or_None, probe_x) for a gadget row."""
    _row, size, chain_color, kind = gadget
    if chain_color == Board.WHITE:
        door_x = WCOL - 1
        chain_xs = list(range(door_x - size, door_x))       # left of door
        approach_x = (door_x - size - 1) if kind == READING else None
        probe_x = door_x - 1
    else:
        door_x = WCOL
        chain_xs = list(range(door_x + 1, door_x + 1 + size))  # right of door
        approach_x = (door_x + size + 1) if kind == READING else None
        probe_x = door_x + 1
    return door_x, chain_xs, approach_x, probe_x


def _build_position(
    gadgets: Sequence[Gadget],
    side_to_move: int,
    black_extra: int,
    rng: Optional[random.Random] = None,
) -> _Built:
    """Construct a settled 9x9 position with the given gadgets.

    ``black_extra`` is a signed baseline knob (each unit shifts ``black - white``
    by 2 uniformly): >0 flips White boundary cells to Black; <0 the reverse.
    Two isolated eyes are carved into each frame for unconditional life.
    """
    gadget_rows = {g[0] for g in gadgets}

    color: Dict[int, int] = {}
    board = Board(SIZE)
    for y in range(SIZE):
        for x in range(SIZE):
            color[board.loc(x, y)] = Board.BLACK if x < WCOL else Board.WHITE

    infos: List[_GadgetInfo] = []
    sensitive: Set[int] = set()
    contested: List[int] = []
    for g in gadgets:
        row, size, chain_color, kind = g
        door_x, chain_xs, approach_x, probe_x = _gadget_geometry(g)
        for x in chain_xs:
            color[board.loc(x, row)] = chain_color
        door = board.loc(door_x, row)
        del color[door]
        approach = None
        if approach_x is not None:
            approach = board.loc(approach_x, row)
            del color[approach]
        info = _GadgetInfo(
            door=door, approach=approach, probe=board.loc(probe_x, row),
            size=size, chain_color=chain_color, kind=kind,
        )
        infos.append(info)
        contested.append(door)
        if approach is not None:
            contested.append(approach)
        cells = list(chain_xs) + [door_x] + ([approach_x] if approach_x is not None else [])
        for x in cells:
            loc = board.loc(x, row)
            sensitive.add(loc)
            for d in board.adj:
                sensitive.add(loc + d)

    _apply_baseline(board, color, gadget_rows, black_extra)
    for loc, c in color.items():
        board.set_stone(c, loc)

    _carve_eyes(board, Board.BLACK, sensitive, rng)
    _carve_eyes(board, Board.WHITE, sensitive, rng)

    return _Built(board=board, contested=contested, gadgets=infos, side_to_move=side_to_move)


def _apply_baseline(
    board: Board, color: Dict[int, int], gadget_rows: Set[int], black_extra: int
) -> None:
    """Flip ``|black_extra|`` boundary cells (on gadget-free rows) to tune the score."""
    rows = [y for y in range(SIZE) if y not in gadget_rows]
    if black_extra > 0:  # White -> Black, marching right from WCOL, keeping cols 7,8 white
        cells = [board.loc(x, y) for x in range(WCOL, SIZE - 2) for y in rows]
        for loc in cells[:black_extra]:
            color[loc] = Board.BLACK
    elif black_extra < 0:  # Black -> White, marching left from WCOL-1, keeping cols 0,1 black
        cells = [board.loc(x, y) for x in range(WCOL - 1, 1, -1) for y in rows]
        for loc in cells[: -black_extra]:
            color[loc] = Board.WHITE


def _carve_eyes(board: Board, eye_color: int, sensitive: Set[int], rng) -> None:
    """Turn two well-separated isolated points of ``eye_color`` into real eyes."""
    candidates: List[int] = []
    for y in range(board.y_size):
        for x in range(board.x_size):
            loc = board.loc(x, y)
            if int(board.board[loc]) != eye_color or loc in sensitive:
                continue
            if all(int(board.board[loc + d]) == eye_color for d in board.adj):
                candidates.append(loc)
    if rng is not None:
        rng.shuffle(candidates)
    chosen: List[int] = []
    for loc in candidates:
        if all(
            abs(board.loc_x(loc) - board.loc_x(c)) + abs(board.loc_y(loc) - board.loc_y(c)) >= 2
            for c in chosen
        ):
            chosen.append(loc)
        if len(chosen) == 2:
            break
    for loc in chosen:
        board.set_stone(Board.EMPTY, loc)


def _count_real_eyes(board: Board, color: int) -> int:
    n = 0
    for y in range(board.y_size):
        for x in range(board.x_size):
            loc = board.loc(x, y)
            if int(board.board[loc]) != Board.EMPTY:
                continue
            neigh = [int(board.board[loc + d]) for d in board.adj]
            if all(c in (color, Board.WALL) for c in neigh) and color in neigh:
                n += 1
    return n


def _connected_component(board: Board, start: int, color: int) -> Set[int]:
    seen = {start}
    stack = [start]
    while stack:
        cur = stack.pop()
        for d in board.adj:
            adj = cur + d
            if int(board.board[adj]) == color and adj not in seen:
                seen.add(adj)
                stack.append(adj)
    return seen


def _frames_alive(built: _Built) -> bool:
    """Each frame is a single connected group with two real eyes (alive)."""
    board = built.board
    chain_cells: Set[int] = set()
    for g in built.gadgets:
        chain_cells |= _connected_component(board, g.probe, int(board.board[g.probe]))
    for color in (Board.BLACK, Board.WHITE):
        frame = {
            board.loc(x, y)
            for y in range(board.y_size)
            for x in range(board.x_size)
            if int(board.board[board.loc(x, y)]) == color and board.loc(x, y) not in chain_cells
        }
        if not frame:
            return False
        comp = _connected_component(board, next(iter(frame)), color) - chain_cells
        if comp != frame:
            return False
        if _count_real_eyes(board, color) < 2:
            return False
    return True


def _contested_empties(board: Board) -> List[int]:
    """Empty on-board points bordering both colours (doors / approaches / dame)."""
    out: List[int] = []
    for loc in empty_points(board):
        cols = {int(board.board[loc + d]) for d in board.adj}
        if Board.BLACK in cols and Board.WHITE in cols:
            out.append(loc)
    return out


def _only_gadget_cells_contested(built: _Built) -> bool:
    """No stray dame: contested empties are exactly the gadget cells, so solving
    over the gadget cells equals solving the full legal-move game."""
    return set(_contested_empties(built.board)) == set(built.contested)


def _validate_gadgets(built: _Built) -> bool:
    """Confirm every chain is present with the right colour, size and liberties."""
    board = built.board
    for g in built.gadgets:
        if int(board.board[g.probe]) != g.chain_color:
            return False
        want_libs = 2 if g.kind == READING else 1
        if board.num_liberties(g.probe) != want_libs:
            return False
        head = board.group_head[g.probe]
        if int(board.group_stone_count[head]) != g.size:
            return False
    return True


# --------------------------------------------------------------------------- #
# Puzzle assembly + certification.
# --------------------------------------------------------------------------- #
@dataclass
class EndgamePuzzle:
    sgf: str
    side_to_move: int
    best_first_moves: List[str]     # GTP coords of the winning first move(s)
    optimal_score: float            # final black - white incl. komi
    difficulty: int = 500
    complexity: int = 0             # measured structural difficulty (for labelling/tests)


def _razor_target(stm: int, optimal0: int) -> int:
    if stm == Board.BLACK:
        return 9 if optimal0 % 2 else 8
    return 7 if optimal0 % 2 else 6


def _analyze(built: _Built):
    """Return (optimal_value, best_move_locs, losing_move_locs) for the side to move."""
    stm = built.side_to_move
    per = EndgameSolver(built.contested).evaluate_root(built.board, stm)
    if not per:
        return None
    if stm == Board.BLACK:
        optimal = max(per.values())
        wins = lambda v: (v - KOMI) > 0
    else:
        optimal = min(per.values())
        wins = lambda v: (KOMI - v) > 0
    best = [loc for loc, v in per.items() if v == optimal]
    losing = [loc for loc, v in per.items() if not wins(v)]
    return per, optimal, best, losing


def _certify(built: _Built) -> Optional[Tuple[int, List[int], List[int]]]:
    """Return ``(optimal, best_moves, losing_moves)`` iff this is a valid puzzle.

    Requirements: the side to move wins by the razor margin under optimal play
    (0 < |result| < 2 after komi), and *every* non-optimal first move loses (so
    any mistake -- wrong reading, wrong region, wrong order -- loses the game).
    There must be at least one losing first move (a real test).
    """
    res = _analyze(built)
    if res is None:
        return None
    per, optimal, best, losing = res
    stm = built.side_to_move
    result = (optimal - KOMI) if stm == Board.BLACK else (KOMI - optimal)
    if not (0 < result < 2):
        return None
    # Every non-optimal-valued first move must lose.
    non_optimal = [loc for loc, v in per.items() if v != optimal]
    if not non_optimal:
        return None
    for loc in non_optimal:
        if loc not in losing:
            return None
    return optimal, best, losing


def _reading_trap_count(built: _Built, best: List[int], losing: Set[int]) -> int:
    """Number of reading gadgets whose door is a winning move and whose approach
    (the natural but wrong atari) is a losing move -- i.e. genuine reading traps
    that the side to move must navigate."""
    n = 0
    best_set = set(best)
    for g in built.gadgets:
        if g.kind == READING and g.approach is not None:
            if g.door in best_set and g.approach in losing:
                n += 1
    return n


def _complexity(built: _Built, best: List[int], losing: List[int]) -> int:
    """A monotone structural-difficulty measure used for labelling and tests."""
    n_regions = len(built.gadgets)
    traps = _reading_trap_count(built, best, set(losing))
    n_losing = len(losing)
    # Close-value pressure: how many distinct winning first moves there are NOT
    # (fewer winning moves + more losing moves == more error-prone).
    return 2 * n_regions + 3 * traps + n_losing


def _gote_color(idx: int, size: int) -> int:
    """A chain colour whose gote size limit admits ``size``, alternating for
    baseline balance."""
    ok = [c for c in (Board.WHITE, Board.BLACK) if _GOTE_MAX[c] >= size]
    if not ok:
        return Board.WHITE
    return ok[idx % len(ok)]


def _choose_layout(rng: random.Random, sched: _Schedule, stm: int) -> List[Gadget]:
    """Pick gadgets (rows, sizes, colours, kinds) honouring the schedule.

    Reading gadgets are chains of the *opponent's* colour (so the side to move
    attacks them and must navigate the trap), and are sized to be pivotal -- as
    big as any gote gadget -- so their door is a winning move and their approach
    a losing one.
    """
    opp = Board.get_opp(stm)
    n = min(sched.n_regions, 5)
    rows = rng.sample([0, 2, 4, 6, 8], n)
    want_traps = sched.n_traps

    gadgets: List[Gadget] = []
    if want_traps >= 1:
        reading_size = _READING_MAX[opp]           # pivotal size (opp WHITE -> 2)
        for i in range(n):
            if i < want_traps:
                gadgets.append((rows[i], reading_size, opp, READING))
            else:
                if sched.closeness >= 0.5:
                    size = rng.randint(max(1, reading_size - 1), reading_size)
                else:
                    size = rng.randint(1, reading_size)
                gadgets.append((rows[i], size, _gote_color(i, size), GOTE))
    else:
        # All gote.  Wide value gaps when easy; closer values when harder.
        if sched.closeness < 0.35 and n <= 3:
            sizes = rng.sample(range(1, 4), min(n, 3))
        else:
            sizes = [rng.randint(1, 3) for _ in range(n)]
            if len(set(sizes)) == 1 and n > 1:
                sizes[0] = 1 if sizes[0] != 1 else 2
        sizes.sort(reverse=True)
        for i in range(n):
            gadgets.append((rows[i], sizes[i], _gote_color(i, sizes[i]), GOTE))
    return gadgets


def generate_endgame_puzzle(difficulty: int, seed: int) -> EndgamePuzzle:
    """Deterministically generate a certified 9x9 endgame puzzle.

    ``difficulty`` is an integer in [1, 999] (clamped).  Same ``(difficulty,
    seed)`` always yields the identical puzzle.
    """
    difficulty = max(DIFFICULTY_MIN, min(DIFFICULTY_MAX, int(difficulty)))
    sched = _schedule(difficulty)
    rng = random.Random()
    rng.seed("katago-endgame-v2|%d|%d" % (difficulty, int(seed)))

    want_traps = sched.n_traps
    for _attempt in range(1200):
        # When reading traps are wanted, Black attacks White reading chains (the
        # bigger, more interesting side); otherwise the side to move is free.
        stm = Board.BLACK if want_traps >= 1 else (
            Board.BLACK if rng.random() < 0.5 else Board.WHITE)
        gadgets = _choose_layout(rng, sched, stm)

        probe = _build_position(gadgets, stm, 0, rng)
        if not _validate_gadgets(probe) or not _frames_alive(probe):
            continue
        res0 = _analyze(probe)
        if res0 is None:
            continue
        per0, optimal0, _b0, _l0 = res0
        black_extra = (_razor_target(stm, optimal0) - optimal0) // 2

        built = _build_position(gadgets, stm, black_extra, rng)
        if not _validate_gadgets(built) or not _frames_alive(built):
            continue
        if not _only_gadget_cells_contested(built):
            continue
        cert = _certify(built)
        if cert is None:
            continue
        optimal, best, losing = cert
        # Require at least one genuine reading trap when the difficulty calls for
        # traps (more reading gadgets are placed at higher difficulty, so more
        # tend to manifest; the complexity metric records how many actually did).
        need_traps = 1 if want_traps >= 1 else 0
        if _reading_trap_count(built, best, set(losing)) < need_traps:
            continue
        return _finish(built, optimal, best, losing, difficulty)

    raise RuntimeError(
        "Failed to generate a certified endgame puzzle for difficulty=%s seed=%s"
        % (difficulty, seed)
    )


def _finish(built: _Built, optimal: int, best: List[int], losing: List[int],
            difficulty: int) -> EndgamePuzzle:
    board = built.board
    stm = built.side_to_move
    result = optimal - KOMI
    best_gtp = sorted(board.loc_to_str(loc) for loc in best)
    stm_char = "Black" if stm == Board.BLACK else "White"
    traps = _reading_trap_count(built, best, set(losing))
    complexity = _complexity(built, best, losing)
    comment = (
        "%s to play. Win the game. Difficulty %d/999. "
        "%d region(s), %d reading trap(s). Correct first move: %s. "
        "Optimal result with best play: %s. "
        "Play until both pass; scored by Tromp-Taylor area, komi %s. "
        "Any suboptimal move loses."
        % (stm_char, difficulty, len(built.gadgets), traps, ", ".join(best_gtp),
           result_string(result), _fmt(KOMI))
    )
    return EndgamePuzzle(
        sgf=to_sgf(board, stm, comment),
        side_to_move=stm,
        best_first_moves=best_gtp,
        optimal_score=result,
        difficulty=difficulty,
        complexity=complexity,
    )


def generate_endgame_sgf(difficulty: int, seed: int) -> str:
    return generate_endgame_puzzle(difficulty, seed).sgf
