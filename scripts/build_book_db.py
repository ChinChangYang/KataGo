#!/usr/bin/env python3
"""Build a compact opening book database from KataGo HTML book files.

Parses HTML files via BFS from root, extracts embedded JavaScript data,
and outputs a compact gzipped file for the iOS app.

Supports two output formats:
  - binary (.kbook.gz): Compact binary format with mmap support (default)
  - json (.json.gz): Legacy JSON format

The --av-threshold flag filters moves by adjusted visits.

Usage:
    # 9x9 (newer 'av' schema):
    python scripts/build_book_db.py \
        --board-size 9 \
        --book-dir ~/Code/KataGoBooks/book9x9jp-20260226 \
        --output book9x9jp-20260226.kbook.gz \
        --av-threshold 10000

    # 6x6/7x7/8x8 (older 'v' schema; archives nest under html/, auto-detected):
    python scripts/build_book_db.py \
        --board-size 6 \
        --book-dir ~/Downloads/book6x6jp-20230525 \
        --output book6x6jp-20230525.kbook.gz

The books come from https://katagobooks.org/downloads/<name>.tar.gz. Older
small-board books embed 'v' (visits) instead of 'av' (adjusted visits); the
builder falls back to 'v' and the --v-threshold automatically.
"""

import argparse
import gzip
import json
import os
import re
import struct
import sys
from collections import deque

# Binary format constants
MAGIC = 0x4B424F4B  # "KBOK"
VERSION = 1
HEADER_SIZE = 32
POSITION_ENTRY_SIZE = 16
MOVE_ENTRY_SIZE = 28
CHILD_ENTRY_SIZE = 8
MOVE_POSITION_ENTRY_SIZE = 1


def parse_html(filepath):
    """Parse a book HTML file and extract the embedded JavaScript data."""
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except OSError as e:
        print(f"Warning: cannot read {filepath}: {e}", file=sys.stderr)
        return None

    # Extract nextPla
    m = re.search(r"const nextPla\s*=\s*(\d+);", content)
    if not m:
        return None
    next_pla = int(m.group(1))

    # Extract links: pos -> relative path
    links = {}
    m = re.search(r"const links\s*=\s*\{(.*?)\};", content, re.DOTALL)
    if m:
        for lm in re.finditer(r"(\d+)\s*:\s*'([^']*)'", m.group(1)):
            pos = int(lm.group(1))
            path = lm.group(2)
            if path:
                links[pos] = path

    # Extract linkSyms: pos -> symmetry int
    link_syms = {}
    m = re.search(r"const linkSyms\s*=\s*\{(.*?)\};", content, re.DOTALL)
    if m:
        for sm in re.finditer(r"(\d+)\s*:\s*(\d+)", m.group(1)):
            link_syms[int(sm.group(1))] = int(sm.group(2))

    # Extract moves array
    moves = []
    m = re.search(r"const moves\s*=\s*\[(.*?)\];", content, re.DOTALL)
    if m:
        for mm in re.finditer(r"\{(.*?)\}", m.group(1), re.DOTALL):
            move_data = mm.group(1)
            move = {}

            # Parse xy arrays
            xy_match = re.search(
                r"'xy'\s*:\s*\[((?:\[\d+,\d+\],?\s*)+)\]", move_data
            )
            if xy_match:
                xy = []
                for pair in re.finditer(r"\[(\d+),(\d+)\]", xy_match.group(1)):
                    xy.append((int(pair.group(1)), int(pair.group(2))))
                move["xy"] = xy

            # Parse pass
            if re.search(r"'move'\s*:\s*'pass'", move_data):
                move["pass"] = True

            # Parse numeric fields
            for field in ["p", "wl", "ssM", "v", "av"]:
                fm = re.search(rf"'{field}'\s*:\s*([-\d.eE]+)", move_data)
                if fm:
                    move[field] = float(fm.group(1))

            moves.append(move)

    return {
        "nextPla": next_pla,
        "links": links,
        "linkSyms": link_syms,
        "moves": moves,
    }


def resolve_link_path(current_filepath, link_path):
    """Resolve a relative link path to an absolute filepath."""
    current_dir = os.path.dirname(current_filepath)
    return os.path.normpath(os.path.join(current_dir, link_path))


def resolve_book_dir(book_dir):
    """Return the directory that directly contains `root/root.html`.

    The 9x9 (2026) archives root at `<book-dir>/root/root.html`, while the older
    small-board archives (6x6/7x7/8x8) nest everything under an `html/` dir, i.e.
    `<book-dir>/html/root/root.html`. Descend into `html/` when needed so callers
    can just point `--book-dir` at the extracted archive root.
    """
    if os.path.exists(os.path.join(book_dir, "root", "root.html")):
        return book_dir
    nested = os.path.join(book_dir, "html")
    if os.path.exists(os.path.join(nested, "root", "root.html")):
        return nested
    return book_dir


def move_metric(move, av_threshold, v_threshold):
    """Return (metric, threshold) for a move, handling both book schemas.

    Newer books embed `av` (adjusted visits, ~1e4 magnitude); older small-board
    books embed only `v` (visits, ~1e9–1e12). Fall back to `v` when `av` is
    absent and compare against the matching threshold.
    """
    if "av" in move:
        return move.get("av", 0), av_threshold
    return move.get("v", 0), v_threshold


def build_book(book_dir, board_size, av_threshold, v_threshold):
    """BFS through book HTML files, building the position database."""
    book_dir = resolve_book_dir(book_dir)
    root_path = os.path.join(book_dir, "root", "root.html")
    if not os.path.exists(root_path):
        print(f"Error: root file not found at {root_path}", file=sys.stderr)
        sys.exit(1)

    # positions[i] = [nextPla, moves_list, children_list]
    # moves_list = [[pos_list, wl, ss, av, p], ...]
    # children_list = [[pos, childId, sym], ...]
    positions = [None]  # index 0 = root
    path_to_id = {os.path.normpath(root_path): 0}
    queue = deque([(os.path.normpath(root_path), 0)])

    processed = 0

    while queue:
        filepath, pos_id = queue.popleft()

        data = parse_html(filepath)
        if data is None:
            positions[pos_id] = [1, [], []]
            processed += 1
            continue

        # Build set of positions for moves above threshold
        threshold_positions = set()
        move_list = []

        for move in data["moves"]:
            metric, threshold = move_metric(move, av_threshold, v_threshold)
            if metric < threshold:
                continue

            pos_list = []
            if "xy" in move:
                for x, y in move["xy"]:
                    pos = y * board_size + x
                    pos_list.append(pos)
                    threshold_positions.add(pos)
            elif move.get("pass"):
                pos = board_size * board_size  # pass sentinel = N*N
                pos_list.append(pos)
                threshold_positions.add(pos)

            wl = round(move.get("wl", 0), 4)
            ss = round(move.get("ssM", 0), 2)
            av_val = int(metric)
            p = round(move.get("p", 0), 4)

            move_list.append([pos_list, wl, ss, av_val, p])

        # Build children list (only for positions meeting threshold)
        children = []
        for pos, link_path in data["links"].items():
            if pos not in threshold_positions:
                continue

            resolved = resolve_link_path(filepath, link_path)
            if not os.path.exists(resolved):
                continue

            if resolved not in path_to_id:
                new_id = len(positions)
                path_to_id[resolved] = new_id
                positions.append(None)
                queue.append((resolved, new_id))

            child_id = path_to_id[resolved]
            link_sym = data["linkSyms"].get(pos, 0)
            children.append([pos, child_id, link_sym])

        positions[pos_id] = [data["nextPla"], move_list, children]

        processed += 1
        if processed % 10000 == 0:
            print(
                f"Processed {processed}/{len(positions)} positions",
                file=sys.stderr,
            )

    return positions


def write_json(positions, output_path, board_size, komi):
    """Write positions as gzipped JSON (legacy format)."""
    book = {
        "m": {"s": board_size, "k": komi},
        "p": positions,
    }

    json_bytes = json.dumps(book, separators=(",", ":")).encode("utf-8")

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with gzip.open(output_path, "wb", compresslevel=9) as f:
        f.write(json_bytes)

    compressed_size = os.path.getsize(output_path)
    print(f"Uncompressed: {len(json_bytes) / 1024 / 1024:.1f} MB", file=sys.stderr)
    print(f"Compressed: {compressed_size / 1024 / 1024:.1f} MB", file=sys.stderr)


def write_binary(positions, output_path, board_size):
    """Write positions as gzipped binary (.kbook) format.

    Binary layout (all little-endian, 4-byte aligned):

    Header (32 bytes):
      UInt32 magic = 0x4B424F4B ("KBOK")
      UInt32 version = 1
      UInt32 boardSize
      UInt32 positionCount
      UInt32 moveCount (total across all positions)
      UInt32 childCount (total across all positions)
      UInt32 movePositionCount (total across all moves)
      UInt32 reserved = 0

    Position Table (positionCount × 16 bytes each):
      UInt8  nextPlayer
      UInt8  _pad
      UInt16 movesCount
      UInt32 movesStart        (index into Moves Table)
      UInt16 childrenCount
      UInt16 _pad2
      UInt32 childrenStart     (index into Children Table)

    Moves Table (moveCount × 28 bytes each):
      UInt32 positionsStart    (index into Move Positions Table)
      UInt8  positionsCount
      UInt8  _pad[3]
      Float32 winLoss
      Float32 sharpScore
      Int64  adjustedVisits
      Float32 policyPrior

    Children Table (childCount × 8 bytes each):
      UInt8  canonicalPos      (0–81)
      UInt8  sym               (0–7)
      UInt16 _pad
      UInt32 childId           (position index)

    Move Positions Table (movePositionCount × 1 byte each):
      UInt8  position          (0–81)
    """
    # First pass: count totals
    total_moves = 0
    total_children = 0
    total_move_positions = 0

    for pos in positions:
        next_pla, moves, children = pos
        total_moves += len(moves)
        total_children += len(children)
        for move in moves:
            total_move_positions += len(move[0])  # pos_list

    print(f"Total moves: {total_moves}", file=sys.stderr)
    print(f"Total children: {total_children}", file=sys.stderr)
    print(f"Total move positions: {total_move_positions}", file=sys.stderr)

    # Second pass: build binary data
    position_count = len(positions)

    # Pre-allocate buffers
    header_buf = bytearray(HEADER_SIZE)
    pos_buf = bytearray(position_count * POSITION_ENTRY_SIZE)
    moves_buf = bytearray(total_moves * MOVE_ENTRY_SIZE)
    children_buf = bytearray(total_children * CHILD_ENTRY_SIZE)
    move_pos_buf = bytearray(total_move_positions * MOVE_POSITION_ENTRY_SIZE)

    # Write header
    struct.pack_into(
        "<IIIIIIII",
        header_buf,
        0,
        MAGIC,
        VERSION,
        board_size,
        position_count,
        total_moves,
        total_children,
        total_move_positions,
        0,  # reserved
    )

    move_idx = 0
    child_idx = 0
    move_pos_idx = 0

    for i, pos in enumerate(positions):
        next_pla, moves, children = pos

        # Write position entry
        struct.pack_into(
            "<BBHIHHI",
            pos_buf,
            i * POSITION_ENTRY_SIZE,
            next_pla,       # UInt8 nextPlayer
            0,              # UInt8 _pad
            len(moves),     # UInt16 movesCount
            move_idx,       # UInt32 movesStart
            len(children),  # UInt16 childrenCount
            0,              # UInt16 _pad2
            child_idx,      # UInt32 childrenStart
        )

        # Write moves for this position
        for move in moves:
            pos_list, wl, ss, av, p = move

            struct.pack_into(
                "<IBBBBffqf",
                moves_buf,
                move_idx * MOVE_ENTRY_SIZE,
                move_pos_idx,     # UInt32 positionsStart
                len(pos_list),    # UInt8 positionsCount
                0,                # UInt8 _pad
                0,                # UInt8 _pad
                0,                # UInt8 _pad
                float(wl),        # Float32 winLoss
                float(ss),        # Float32 sharpScore
                int(av),          # Int64 adjustedVisits
                float(p),         # Float32 policyPrior
            )

            # Write move positions
            for mp in pos_list:
                struct.pack_into("<B", move_pos_buf, move_pos_idx, mp)
                move_pos_idx += 1

            move_idx += 1

        # Write children for this position
        for child in children:
            c_pos, c_child_id, c_sym = child

            struct.pack_into(
                "<BBHI",
                children_buf,
                child_idx * CHILD_ENTRY_SIZE,
                c_pos,       # UInt8 canonicalPos
                c_sym,       # UInt8 sym
                0,           # UInt16 _pad
                c_child_id,  # UInt32 childId
            )
            child_idx += 1

    # Combine all buffers
    binary_data = bytes(header_buf) + bytes(pos_buf) + bytes(moves_buf) + bytes(children_buf) + bytes(move_pos_buf)

    # Pad to 4-byte alignment
    remainder = len(binary_data) % 4
    if remainder:
        binary_data += b"\x00" * (4 - remainder)

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with gzip.open(output_path, "wb", compresslevel=9) as f:
        f.write(binary_data)

    compressed_size = os.path.getsize(output_path)
    print(
        f"Uncompressed: {len(binary_data) / 1024 / 1024:.1f} MB", file=sys.stderr
    )
    print(f"Compressed: {compressed_size / 1024 / 1024:.1f} MB", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Build compact opening book database from KataGo HTML book files"
    )
    parser.add_argument(
        "--book-dir", required=True, help="Path to KataGo book directory"
    )
    parser.add_argument(
        "--output", required=True, help="Output path for gzipped book file"
    )
    parser.add_argument(
        "--board-size", type=int, required=True,
        help="Board size N (6...9). Written to the header and used for all coord math.",
    )
    parser.add_argument(
        "--av-threshold",
        type=int,
        default=10000,
        help="Minimum adjusted visits ('av' books) to include a move (default: 10000)",
    )
    parser.add_argument(
        "--v-threshold",
        type=int,
        default=0,
        help="Minimum visits ('v' books, older small-board) to include a move "
             "(default: 0 = include all; small-board books are small)",
    )
    parser.add_argument(
        "--komi", type=float, default=6.0,
        help="Komi for the JSON metadata only (default: 6.0). Unused by the binary format.",
    )
    parser.add_argument(
        "--format",
        choices=["json", "binary"],
        default="binary",
        help="Output format: 'binary' (.kbook.gz, default) or 'json' (.json.gz, legacy)",
    )
    args = parser.parse_args()

    if not (6 <= args.board_size <= 9):
        print(f"Error: --board-size must be 6...9, got {args.board_size}", file=sys.stderr)
        sys.exit(1)

    print(
        f"Building {args.board_size}x{args.board_size} book from {args.book_dir} "
        f"(av >= {args.av_threshold}, v >= {args.v_threshold})",
        file=sys.stderr,
    )

    positions = build_book(args.book_dir, args.board_size, args.av_threshold, args.v_threshold)

    # Replace None entries (unreachable positions)
    for i in range(len(positions)):
        if positions[i] is None:
            positions[i] = [1, [], []]

    print(f"Total positions: {len(positions)}", file=sys.stderr)

    if args.format == "json":
        write_json(positions, args.output, args.board_size, args.komi)
    else:
        write_binary(positions, args.output, args.board_size)

    print("Done!", file=sys.stderr)


if __name__ == "__main__":
    main()
