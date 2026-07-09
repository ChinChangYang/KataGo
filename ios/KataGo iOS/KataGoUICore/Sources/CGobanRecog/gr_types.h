//
//  gr_types.h
//  CGobanRecog
//
//  Ports gobanrecog/types.py. INTERNAL header (plain std types only; kept out
//  of include/ so it is not exported to Swift). GroundTruth is intentionally
//  dropped (synth-only, port-conventions.md gr_types row).
//
//  Board coordinates: (col, row) with col = x (left->right), row = y
//  (top->bottom), both 0-based, in IMAGE orientation (row 0 = topmost row of
//  the board as seen in the photo). rows[row][col] storage — note stone_at's
//  (col,row) argument order vs the rows[row][col] index order.
//

#ifndef gr_types_h
#define gr_types_h

#include <string>
#include <utility>
#include <vector>

namespace gobanrecog {

// Stone states (types.py:18-20).
constexpr char EMPTY = '.';
constexpr char BLACK = 'B';
constexpr char WHITE = 'W';

// types.py:22
inline constexpr int SUPPORTED_SIZES[] = {9, 13, 19};

/// A static board position. rows[row][col], row 0 = topmost image row.
/// Ports types.py::BoardState (frozen dataclass). Construction runs the same
/// validation as Python's __post_init__ and throws std::invalid_argument with
/// equivalent messages.
struct BoardState {
    int size;
    std::vector<std::string> rows;

    // Ports BoardState.__post_init__ (types.py:34-44).
    BoardState(int size, std::vector<std::string> rows);

    // Ports BoardState.stone_at (types.py:46-47): preserves the (col,row)
    // argument order against the rows[row][col] storage swap.
    char stoneAt(int col, int row) const;

    // Ports BoardState.points (types.py:49-56): all (col,row) holding `color`,
    // sorted row-major (top-to-bottom, left-to-right).
    std::vector<std::pair<int, int>> points(char color) const;

    // Ports BoardState.empty (types.py:58-60).
    static BoardState empty(int size);

    // Ports BoardState.from_grid (types.py:62-64).
    static BoardState fromGrid(const std::vector<std::vector<char>>& grid);
};

}  // namespace gobanrecog

#endif /* gr_types_h */
