//
//  gr_types.cpp
//  CGobanRecog
//
//  ports gobanrecog/types.py::BoardState
//

#include "gr_types.h"

#include <algorithm>
#include <set>
#include <stdexcept>
#include <string>

namespace gobanrecog {

namespace {

bool isSupportedSize(int size) {
    for (int s : SUPPORTED_SIZES) {
        if (s == size) return true;
    }
    return false;
}

bool isValidChar(char c) {
    return c == EMPTY || c == BLACK || c == WHITE;
}

// Reproduces Python's f"{sorted(bad)}" for a set of single-char strings, e.g.
// "['X', 'Z']". `bad` = the unique invalid chars in a row (types.py:42).
std::string formatSortedBad(const std::string& row) {
    std::set<char> bad;  // std::set = unique + ascending, matching sorted(set(...))
    for (char c : row) {
        if (!isValidChar(c)) bad.insert(c);
    }
    std::string out = "[";
    bool first = true;
    for (char c : bad) {
        if (!first) out += ", ";
        first = false;
        out += '\'';
        out += c;
        out += '\'';
    }
    out += "]";
    return out;
}

}  // namespace

// ports types.py::BoardState.__post_init__
BoardState::BoardState(int size, std::vector<std::string> rows)
    : size(size), rows(std::move(rows)) {
    if (!isSupportedSize(this->size)) {
        throw std::invalid_argument("unsupported board size " + std::to_string(this->size));
    }
    if (static_cast<int>(this->rows.size()) != this->size) {
        throw std::invalid_argument("expected " + std::to_string(this->size) +
                                    " rows, got " + std::to_string(this->rows.size()));
    }
    for (size_t i = 0; i < this->rows.size(); ++i) {
        const std::string& row = this->rows[i];
        if (static_cast<int>(row.size()) != this->size) {
            throw std::invalid_argument("row " + std::to_string(i) + " has length " +
                                        std::to_string(row.size()) + ", expected " +
                                        std::to_string(this->size));
        }
        std::string bad;
        for (char c : row) {
            if (!isValidChar(c)) { bad = row; break; }
        }
        if (!bad.empty()) {
            throw std::invalid_argument("row " + std::to_string(i) +
                                        " contains invalid chars " + formatSortedBad(row));
        }
    }
}

// ports types.py::BoardState.stone_at
char BoardState::stoneAt(int col, int row) const {
    return rows[row][col];
}

// ports types.py::BoardState.points
std::vector<std::pair<int, int>> BoardState::points(char color) const {
    std::vector<std::pair<int, int>> out;
    for (int row = 0; row < size; ++row) {
        for (int col = 0; col < size; ++col) {
            if (rows[row][col] == color) out.emplace_back(col, row);
        }
    }
    return out;
}

// ports types.py::BoardState.empty
BoardState BoardState::empty(int size) {
    std::vector<std::string> rows(static_cast<size_t>(size), std::string(static_cast<size_t>(size), EMPTY));
    return BoardState(size, std::move(rows));
}

// ports types.py::BoardState.from_grid
BoardState BoardState::fromGrid(const std::vector<std::vector<char>>& grid) {
    std::vector<std::string> rows;
    rows.reserve(grid.size());
    for (const auto& r : grid) {
        rows.emplace_back(r.begin(), r.end());
    }
    return BoardState(static_cast<int>(grid.size()), std::move(rows));
}

}  // namespace gobanrecog
