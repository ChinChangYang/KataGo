//
//  gr_sgf.h
//  CGobanRecog
//
//  Ports gobanrecog/sgf.py::board_to_sgf (the SETUP-POSITION writer only).
//  INTERNAL header (plain std types + BoardState; no cv:: types; kept out of
//  include/).
//
//  SGF point convention (sgf.py): two lowercase letters, FIRST letter is the
//  column (x, left->right), second is the row (y, top->bottom); "aa" is the
//  top-left. Setup points are emitted AB (black) then AW (white), each in the
//  board's row-major point order (BoardState::points).
//
//  NOTE (Task 9): this C++ writer exists ONLY for the gobanrecog-cli / 600-image
//  eval-vs-Python parity. It is a FAITHFUL board_to_sgf clone with NO rules tags
//  (RU/KM/PL) — the app's real SGF (with rules/komi/player) is synthesized
//  Swift-side in Task 11. sgf.py's parser (sgf_to_board) is synth/test-only and
//  is intentionally not ported.
//

#ifndef gr_sgf_h
#define gr_sgf_h

#include <string>

#include "gr_types.h"

namespace gobanrecog {

// ports sgf.py::board_to_sgf.
//   "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[n]AB[..]..AW[..]..)"
// AB/AW sections are omitted when the color has no stones (sgf.py's `if pts`).
std::string board_to_sgf(const BoardState& board);

}  // namespace gobanrecog

#endif /* gr_sgf_h */
