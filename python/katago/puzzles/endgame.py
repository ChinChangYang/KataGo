"""Algorithm-only 9x9 endgame ("biggest move") puzzle generator.

No neural net is involved.  A puzzle is a settled 9x9 position, area-scored
under Tromp-Taylor rules with komi 7.5, in which the side to move wins the game
*if and only if* they play the biggest endgame moves in the correct order.  Any
suboptimal move, against best play by the opponent, flips the result to a loss.

Correctness is *certified at generation time* by exact minimax search over the
small set of contested points, so the generator never guesses -- it constructs a
candidate, solves it exactly, and only emits positions that provably have the
required "correct play wins / any mistake loses" property.

The contested regions are independent "capture-or-connect" gadgets.  A gadget is
a chain of ``k`` stones enclosed on three sides, with a single shared liberty
``q`` (the "door") that is also adjacent to that colour's own living wall.
Whoever plays ``q`` first wins the gadget's ``k + 1`` points for their colour:
the enemy of the chain captures it, the owner connects it to safety.  Gadgets
come in both orientations (White chains that Black captures, and Black chains
that White captures), which balances the position and means each side simply
wants the biggest available door on its turn.  Because the chain sizes are
distinct, every mistake costs at least one point, and the razor-thin margin turns
any mistake into a loss.

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
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Set, Tuple

from katago.game.board import Board

KOMI = 7.5
SIZE = 9
WCOL = 5  # boundary: Black frame is columns 0..4, White frame is columns 5..8.

# SGF point letters: index 0->'a' .. 25->'z', 26->'A' ..  (top-origin, column x
# then row y), identical to KataGo's WriteSgf::writeSgfLoc encoding.
_SGF_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


# --------------------------------------------------------------------------- #
# Scoring: Tromp-Taylor area scoring.
# --------------------------------------------------------------------------- #
def area_score(board: Board) -> Tuple[int, int]:
    """Return ``(black_area, white_area)`` under Tromp-Taylor area scoring.

    Every stone counts for its colour.  Every maximal empty region counts for a
    colour iff every stone bordering it is that colour; regions bordering both
    colours (dame) count for neither.
    """
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
                        # WALL: ignore
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
    Tromp-Taylor area score ``black - white``.  ``to_move`` picks the move that
    maximises ``black - white`` for Black and minimises it for White.
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
        key = (int(board.pos_zobrist()), to_move, passes)
        cached = self._memo.get(key)
        if cached is not None:
            return cached

        opp = Board.get_opp(to_move)
        maximizing = to_move == Board.BLACK
        best: Optional[int] = None
        for loc in self._candidates(board, to_move):
            child = board.copy()
            child.play(to_move, loc)
            v = self._value(child, opp, 0)
            if best is None or (v > best if maximizing else v < best):
                best = v
        # Pass is always available.
        child = board.copy()
        child.play(to_move, Board.PASS_LOC)
        v = self._value(child, opp, passes + 1)
        if best is None or (v > best if maximizing else v < best):
            best = v

        self._memo[key] = best
        return best

    def evaluate_root(self, board: Board, to_move: int) -> Dict[int, int]:
        """Value (``black - white`` at game end) of each legal first move.

        Keys are contested locations; the pass move is excluded (a real puzzle is
        never solved by passing first).
        """
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
    optimal move location(s) for ``to_move`` in an endgame position.

    Candidate moves are every empty on-board point that is legal for ``to_move``.
    Intended for an app to use this module as an algorithm-only endgame opponent
    or grader.  For large open positions this is expensive; it is meant for
    settled endgames like the ones this module generates.
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
    """Serialise a setup position to a single-line SGF string.

    Produces ``AB``/``AW`` setup stones and an explicit ``PL`` for the side to
    move (KataGo's own writer omits ``PL``; a setup puzzle needs it).  No ``RE``
    is written -- the game has not been played; the intended result lives in the
    comment.
    """
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
# Difficulty.
# --------------------------------------------------------------------------- #
class Difficulty(enum.IntEnum):
    VERY_EASY = 1
    EASY = 2
    MEDIUM = 3
    HARD = 4
    VERY_HARD = 5


# Orientation policies for the gadget set:
#   "capture" -- every gadget is an enemy chain the side to move captures.
#   "mixed"   -- at least one gadget is the side-to-move's own chain, so the
#                player must value defending (connecting) as well as capturing.
#   "defense" -- mixed, and the single biggest move is a defence of the side to
#                move's own group (the hardest to spot).
@dataclass
class _DiffParams:
    num_gadgets: int   # how many contested gadgets (moves to order correctly)
    min_gap: int       # min difference between adjacent gadget sizes
    policy: str


def _difficulty_params(difficulty: Difficulty) -> _DiffParams:
    # Distinct gadget values on a 9x9 board are limited to {2,3,4} (chains must
    # leave a connecting column so a frame is never split), so difficulty scales
    # by gadget count, size spacing, and how much defence the player must read.
    return {
        Difficulty.VERY_EASY: _DiffParams(num_gadgets=2, min_gap=2, policy="capture"),
        Difficulty.EASY:      _DiffParams(num_gadgets=2, min_gap=1, policy="capture"),
        Difficulty.MEDIUM:    _DiffParams(num_gadgets=3, min_gap=1, policy="capture"),
        Difficulty.HARD:      _DiffParams(num_gadgets=3, min_gap=1, policy="mixed"),
        Difficulty.VERY_HARD: _DiffParams(num_gadgets=3, min_gap=1, policy="defense"),
    }[difficulty]


# --------------------------------------------------------------------------- #
# Position construction.
# --------------------------------------------------------------------------- #
# A gadget is (row, size, orient).  orient == Board.WHITE means a White chain in
# Black's area that Black captures / White connects (door on the Black side of the
# boundary).  orient == Board.BLACK is the mirror image in White's area.
Gadget = Tuple[int, int, int]

# Chain-size limits at the WCOL=5 boundary.  Chains must NOT span a frame's full
# width, or they split the frame into two one-eyed (killable) groups.  Leaving one
# connecting column caps White chains at WCOL-2=3 and Black chains at
# SIZE-WCOL-2=2, so the distinct gadget sizes available are {1, 2, 3}.
_MAX_W_SIZE = WCOL - 2          # 3  (keeps column 0 black -> frame stays joined)
_MAX_B_SIZE = SIZE - WCOL - 2   # 2  (keeps column 8 white -> frame stays joined)


@dataclass
class _Built:
    board: Board
    contested: List[int]        # door locations q, one per gadget
    gadget_doors: List[int]     # door loc per gadget (same order as gadget_sizes)
    gadget_sizes: List[int]
    gadget_orients: List[int]
    chain_probe: List[int]      # one chain stone per gadget (for validation)
    side_to_move: int


def _gadget_cells(gadget: Gadget):
    """Return (door_x, chain_xs, chain_color, probe_x) for a gadget on its row."""
    row, k, orient = gadget
    if orient == Board.WHITE:
        door_x = WCOL - 1
        chain_xs = list(range(door_x - k, door_x))   # left of the door
        return door_x, chain_xs, Board.WHITE, door_x - 1
    else:
        door_x = WCOL
        chain_xs = list(range(door_x + 1, door_x + 1 + k))  # right of the door
        return door_x, chain_xs, Board.BLACK, door_x + 1


def _build_position(
    gadgets: Sequence[Gadget],
    side_to_move: int,
    black_extra: int,
    rng: Optional[random.Random] = None,
) -> _Built:
    """Construct a settled 9x9 position with capture-or-connect gadgets.

    ``black_extra`` is a signed baseline knob (each unit shifts ``black - white``
    by 2 uniformly): ``>0`` flips White boundary points to Black marching right
    from column WCOL; ``<0`` flips Black boundary points to White marching left
    from column WCOL-1.  Flips only touch rows with no gadget and keep the two
    outermost columns of each colour intact (so each frame stays connected and
    can host two eyes).
    """
    gadget_rows = {row for row, _, _ in gadgets}

    # Default frame colours.
    color: Dict[int, int] = {}
    board = Board(SIZE)
    for y in range(SIZE):
        for x in range(SIZE):
            color[board.loc(x, y)] = Board.BLACK if x < WCOL else Board.WHITE

    doors: List[int] = []
    sizes: List[int] = []
    orients: List[int] = []
    probes: List[int] = []
    sensitive: Set[int] = set()

    for g in gadgets:
        row, k, orient = g
        door_x, chain_xs, chain_color, probe_x = _gadget_cells(g)
        door = board.loc(door_x, row)
        del color[door]  # door stays empty
        for x in chain_xs:
            color[board.loc(x, row)] = chain_color
        doors.append(door)
        sizes.append(k)
        orients.append(orient)
        probes.append(board.loc(probe_x, row))
        # Mark gadget cells (and their neighbours) off-limits for eye carving.
        for x in chain_xs + [door_x]:
            loc = board.loc(x, row)
            sensitive.add(loc)
            for d in board.adj:
                sensitive.add(loc + d)

    _apply_baseline(board, color, gadget_rows, black_extra)

    for loc, c in color.items():
        board.set_stone(c, loc)

    _carve_eyes(board, Board.BLACK, sensitive, rng)
    _carve_eyes(board, Board.WHITE, sensitive, rng)

    # The doors are the only contested points: every other empty is a real eye
    # (fillable only by its owner, and strictly dominated by passing) and there is
    # no dame.  A generation-time check (_only_doors_contested) enforces that, so
    # solving over just the doors equals solving the full legal-move game -- while
    # keeping the search tiny.
    return _Built(
        board=board,
        contested=list(doors),
        gadget_doors=doors,
        gadget_sizes=sizes,
        gadget_orients=orients,
        chain_probe=probes,
        side_to_move=side_to_move,
    )


def _apply_baseline(
    board: Board, color: Dict[int, int], gadget_rows: Set[int], black_extra: int
) -> None:
    """Flip ``|black_extra|`` boundary cells to tune the score, in place."""
    non_gadget_rows = [y for y in range(SIZE) if y not in gadget_rows]
    if black_extra > 0:
        # White -> Black, marching right from WCOL, keeping columns 7,8 white.
        cells = [
            board.loc(x, y)
            for x in range(WCOL, SIZE - 2)
            for y in non_gadget_rows
        ]
        for loc in cells[:black_extra]:
            color[loc] = Board.BLACK
    elif black_extra < 0:
        # Black -> White, marching left from WCOL-1, keeping columns 0,1 black.
        cells = [
            board.loc(x, y)
            for x in range(WCOL - 1, 1, -1)
            for y in non_gadget_rows
        ]
        for loc in cells[: -black_extra]:
            color[loc] = Board.WHITE


def _carve_eyes(
    board: Board,
    eye_color: int,
    sensitive: Set[int],
    rng: Optional[random.Random],
) -> None:
    """Turn two isolated single points of ``eye_color``'s mass into real eyes.

    Picks two well-separated points that are currently ``eye_color`` stones, whose
    four orthogonal neighbours are all ``eye_color``, and that are away from any
    gadget (``sensitive``) so emptying them cannot free a chain.
    """
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
        # Manhattan distance >= 2 keeps the eyes from being orthogonally adjacent
        # (which would merge them into one two-space region rather than two eyes).
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
    """Number of single empty points fully surrounded by ``color`` (real eyes)."""
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
    """All ``color`` stones connected to ``start`` by orthogonal adjacency."""
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
    """Each frame is a single connected group with two real eyes.

    Gadget chains are isolated groups of their own colour (surrounded by the
    enemy), so they are excluded; every other stone of a colour must form one
    connected group (the frame), and that frame must have >= 2 real eyes -- i.e.
    be unconditionally alive and un-invadable.
    """
    board = built.board
    chain_cells: Set[int] = set()
    for probe in built.chain_probe:
        chain_cells |= _connected_component(board, probe, int(board.board[probe]))

    for color in (Board.BLACK, Board.WHITE):
        frame = {
            board.loc(x, y)
            for y in range(board.y_size)
            for x in range(board.x_size)
            if int(board.board[board.loc(x, y)]) == color
            and board.loc(x, y) not in chain_cells
        }
        if not frame:
            return False
        comp = _connected_component(board, next(iter(frame)), color) - chain_cells
        if comp != frame:  # frame split into disconnected pieces
            return False
        if _count_real_eyes(board, color) < 2:
            return False
    return True


def _contested_empties(board: Board) -> List[int]:
    """Empty on-board points bordering both colours (doors / dame)."""
    out: List[int] = []
    for loc in empty_points(board):
        cols = {int(board.board[loc + d]) for d in board.adj}
        if Board.BLACK in cols and Board.WHITE in cols:
            out.append(loc)
    return out


def _only_doors_contested(built: _Built) -> bool:
    """No stray dame: the doors are exactly the both-colour-bordering empties, so
    solving over the doors is the same game as the full legal-move game."""
    return set(_contested_empties(built.board)) == set(built.gadget_doors)


def _validate_gadgets(built: _Built) -> bool:
    """Confirm every gadget chain is in atari with its door as the sole liberty."""
    board = built.board
    for probe, orient, k in zip(built.chain_probe, built.gadget_orients, built.gadget_sizes):
        if int(board.board[probe]) != orient:
            return False
        if board.num_liberties(probe) != 1:
            return False
        head = board.group_head[probe]
        if int(board.group_stone_count[head]) != k:
            return False
    return True


# --------------------------------------------------------------------------- #
# Puzzle assembly + certification.
# --------------------------------------------------------------------------- #
@dataclass
class EndgamePuzzle:
    sgf: str
    side_to_move: int
    best_first_moves: List[str]     # GTP coords, e.g. ["C3"]
    optimal_score: float            # final black - white incl. komi
    difficulty: Difficulty = field(default=Difficulty.MEDIUM)


def _certify(built: _Built) -> Optional[Tuple[int, List[int]]]:
    """Return ``(optimal_black_minus_white, best_move_locs)`` iff this position is
    a valid "biggest move wins" puzzle, else ``None``.

    Requirements:
      * exactly one strictly-best first move (a unique biggest point),
      * the side to move wins by the minimal decisive margin under optimal play
        (0 < |result| < 2 after komi), and
      * every other first move loses for the side to move.
    """
    stm = built.side_to_move
    solver = EndgameSolver(built.contested)
    per_move = solver.evaluate_root(built.board, stm)
    if len(per_move) < 2:
        return None

    if stm == Board.BLACK:
        optimal = max(per_move.values())
        result = optimal - KOMI
        wins = lambda v: (v - KOMI) > 0
    else:
        optimal = min(per_move.values())
        result = KOMI - optimal
        wins = lambda v: (KOMI - v) > 0

    best_moves = [loc for loc, v in per_move.items() if v == optimal]
    if len(best_moves) != 1:
        return None
    if not (0 < result < 2):
        return None
    for loc, v in per_move.items():
        if loc not in best_moves and wins(v):
            return None
    return optimal, best_moves


def _razor_target(stm: int, optimal0: int) -> int:
    """Baseline target for ``black - white`` giving the minimal decisive win for
    ``stm`` (result of +/-0.5 or +/-1.5), matching the parity of ``optimal0`` so
    the required baseline shift is an even number of units."""
    if stm == Board.BLACK:
        return 9 if optimal0 % 2 else 8
    return 7 if optimal0 % 2 else 6


def _choose_layout(
    rng: random.Random, params: _DiffParams
) -> Tuple[List[Gadget], int]:
    """Pick distinct gadget sizes, orientations, rows and the side to move.

    White chains realise sizes 1..3, Black chains sizes 1..2, so the biggest size
    (3) is always a White chain.  The orientation policy decides how many gadgets
    are the side-to-move's own chains (defences) versus captures.
    """
    n = params.num_gadgets
    sizes = sorted(_distinct_sizes(rng, n, params.min_gap), reverse=True)  # big first

    if params.policy == "defense":
        # Side to move is White so the biggest (White) chain is White's OWN group;
        # its best move is to connect/defend it rather than capture.
        stm = Board.WHITE
    else:
        stm = Board.BLACK if rng.random() < 0.5 else Board.WHITE

    orients: List[int] = []
    for idx, s in enumerate(sizes):
        if s > _MAX_B_SIZE:
            orients.append(Board.WHITE)      # size 3 must be White
        elif params.policy == "capture":
            # Every gadget is an enemy chain of the side to move.
            orients.append(Board.get_opp(stm))
        elif idx == 0 and params.policy == "defense":
            orients.append(stm)              # biggest is the mover's own group
        else:
            orients.append(Board.BLACK if rng.random() < 0.5 else Board.WHITE)

    # "mixed" must contain at least one of the mover's own chains (a defence).
    if params.policy == "mixed" and stm not in orients:
        swap = next((i for i, s in enumerate(sizes) if s <= _MAX_B_SIZE), None)
        if swap is not None:
            orients[swap] = stm

    rows = rng.sample([0, 2, 4, 6, 8], n)
    gadgets = [(rows[i], sizes[i], orients[i]) for i in range(n)]
    return gadgets, stm


def _distinct_sizes(rng: random.Random, n: int, min_gap: int) -> List[int]:
    hi = _MAX_W_SIZE
    if min_gap >= 2:
        pool = list(range(1, hi + 1))
        sizes: List[int] = []
        for s in sorted(pool, reverse=True):
            if all(abs(s - t) >= min_gap for t in sizes):
                sizes.append(s)
            if len(sizes) == n:
                break
        if len(sizes) == n:
            rng.shuffle(sizes)
            return sizes
    return rng.sample(range(1, hi + 1), n)


def generate_endgame_puzzle(difficulty: Difficulty, seed: int) -> EndgamePuzzle:
    """Deterministically generate a certified 9x9 endgame puzzle.

    Same ``(difficulty, seed)`` always yields the identical puzzle.
    """
    difficulty = Difficulty(int(difficulty))
    params = _difficulty_params(difficulty)
    rng = random.Random()
    rng.seed("katago-endgame|%d|%d" % (int(difficulty), int(seed)))

    for _attempt in range(400):
        gadgets, stm = _choose_layout(rng, params)

        # Probe at neutral baseline; baseline shifts translate every value by 2,
        # so we can compute the exact knob needed for a razor margin directly.
        probe = _build_position(gadgets, stm, 0, rng)
        if not _validate_gadgets(probe) or not _frames_alive(probe):
            continue
        per0 = EndgameSolver(probe.contested).evaluate_root(probe.board, stm)
        if len(per0) < len(gadgets):
            continue
        optimal0 = max(per0.values()) if stm == Board.BLACK else min(per0.values())
        black_extra = (_razor_target(stm, optimal0) - optimal0) // 2

        built = _build_position(gadgets, stm, black_extra, rng)
        if not _validate_gadgets(built) or not _frames_alive(built):
            continue
        if not _only_doors_contested(built):
            continue
        cert = _certify(built)
        if cert is not None:
            optimal, best_moves = cert
            return _finish(built, optimal, best_moves, difficulty)

    raise RuntimeError(
        "Failed to generate a certified endgame puzzle for difficulty=%s seed=%s"
        % (difficulty, seed)
    )


def _finish(
    built: _Built,
    optimal: int,
    best_moves: List[int],
    difficulty: Difficulty,
) -> EndgamePuzzle:
    board = built.board
    stm = built.side_to_move
    result = optimal - KOMI
    best_gtp = [board.loc_to_str(loc) for loc in best_moves]
    stm_char = "Black" if stm == Board.BLACK else "White"
    comment = (
        "%s to play. Win the game by playing the biggest endgame move first. "
        "Best move: %s. Optimal result with best play: %s. "
        "Play until both pass; scored by Tromp-Taylor area, komi %s."
        % (stm_char, ", ".join(best_gtp), result_string(result), _fmt(KOMI))
    )
    sgf = to_sgf(board, stm, comment)
    return EndgamePuzzle(
        sgf=sgf,
        side_to_move=stm,
        best_first_moves=best_gtp,
        optimal_score=result,
        difficulty=difficulty,
    )


def generate_endgame_sgf(difficulty: Difficulty, seed: int) -> str:
    return generate_endgame_puzzle(difficulty, seed).sgf
