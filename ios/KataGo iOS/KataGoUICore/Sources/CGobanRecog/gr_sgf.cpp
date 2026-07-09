//
//  gr_sgf.cpp
//  CGobanRecog
//
//  ports gobanrecog/sgf.py::board_to_sgf (setup-position writer).
//

#include "gr_sgf.h"

#include <string>
#include <utility>
#include <vector>

#include "GobanRecogTestBridge.hpp"

namespace gobanrecog {

namespace {

// ports sgf.py::_point: column-letter FIRST (col = x), then the row letter.
std::string point(int col, int row) {
    std::string s;
    s += static_cast<char>('a' + col);
    s += static_cast<char>('a' + row);
    return s;
}

}  // namespace

// ports sgf.py::board_to_sgf.
std::string board_to_sgf(const BoardState& board) {
    std::string parts =
        "(;GM[1]FF[4]CA[UTF-8]AP[GobanRecog:0.1]SZ[" + std::to_string(board.size) + "]";
    // sgf.py:20 iterates ("AB", BLACK) then ("AW", WHITE).
    const std::pair<const char*, char> propColors[2] = {{"AB", BLACK}, {"AW", WHITE}};
    for (const auto& pc : propColors) {
        const std::vector<std::pair<int, int>> pts = board.points(pc.second);
        if (!pts.empty()) {  // sgf.py's `if pts`
            parts += pc.first;
            for (const auto& cr : pts) {  // cr = (col, row)
                parts += '[';
                parts += point(cr.first, cr.second);
                parts += ']';
            }
        }
    }
    parts += ')';
    return parts;
}

// ---- test bridge (cv-free seam; see GobanRecogTestBridge.hpp) --------------
namespace testbridge {

std::string sgf_board_to_sgf(int size, const char* rowsNL) {
    // Split the newline-joined rows exactly as the other board_* bridges do.
    std::vector<std::string> rows;
    std::string cur;
    for (const char* p = rowsNL; *p != '\0'; ++p) {
        if (*p == '\n') {
            rows.push_back(cur);
            cur.clear();
        } else {
            cur += *p;
        }
    }
    rows.push_back(cur);
    try {
        const BoardState board(size, std::move(rows));
        return board_to_sgf(board);
    } catch (const std::exception&) {
        return "!";
    }
}

}  // namespace testbridge

}  // namespace gobanrecog
