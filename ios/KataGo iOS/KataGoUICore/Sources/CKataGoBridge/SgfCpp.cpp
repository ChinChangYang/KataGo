//
//  SgfCpp.cpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/8.
//

#include "SgfCpp.hpp"
#include "sgf.h"

LocCpp::LocCpp() {
    this->x = -1;
    this->y = -1;
    this->pass = true;
}

LocCpp::LocCpp(const int x, const int y) {
    this->x = x;
    this->y = y;
    this->pass = false;
}

LocCpp::LocCpp(const LocCpp& loc) {
    this->x = loc.x;
    this->y = loc.y;
    this->pass = loc.pass;
}

int LocCpp::getX() const {
    return x;
}

int LocCpp::getY() const {
    return y;
}

bool LocCpp::getPass() const {
    return pass;
}

MoveCpp::MoveCpp(const LocCpp& loc, const PlayerCpp player): loc(loc) {
    this->_player = player;
}

int MoveCpp::getX() const {
    return loc.getX();
}

int MoveCpp::getY() const {
    return loc.getY();
}

bool MoveCpp::getPass() const {
    return loc.getPass();
}

PlayerCpp MoveCpp::getPlayer() const {
    return _player;
}

SgfCpp::SgfCpp(const string& str) : sgf(nullptr), _xSize(0), _ySize(0) {
    try {
        sgf = Sgf::parse(str).release();
        if (sgf != NULL) {
            auto size = ((Sgf*)sgf)->getXYSize();
            _xSize = size.x;
            _ySize = size.y;
            traverseSgf(sgf);
        }
    } catch (...) {
        sgf = NULL;
    }
}

void SgfCpp::traverseSgf(const void* sgf) {
    // Clear any existing moves and comments
    moves.clear();
    comments.clear();
    // Start the traversal
    traverseSgfHelper(sgf);
}

static const int COORD_MAX = 128;

void SgfCpp::traverseSgfHelper(const void* sgf) {
    // Iterate over the nodes in this sgf
    for (size_t i = 0; i < ((Sgf*)sgf)->nodes.size(); ++i) {
        const SgfNode* node = ((Sgf*)sgf)->nodes[i].get();

        // Extract move if present
        if (node->move.pla != C_EMPTY) {
            LocCpp locCpp;
            if ((node->move.x == COORD_MAX && node->move.y == COORD_MAX) ||
                (node->move.x == 19 && node->move.y == 19 && (_xSize <= 19 || _ySize <= 19))) {
                locCpp = LocCpp(); // Pass move
            } else {
                int x = node->move.x;
                int y = node->move.y;
                locCpp = LocCpp(x, y);
            }
            PlayerCpp playerCpp = (node->move.pla == P_BLACK) ? PlayerCpp::black : PlayerCpp::white;
            MoveCpp moveCpp(locCpp, playerCpp);
            moves.push_back(moveCpp);
        }

        // Extract comment
        string comment = "";
        if (node->hasProperty("C")) {
            comment = node->getSingleProperty("C");
        }
        comments.push_back(comment);
    }

    // Find the child with the maximum depth
    const Sgf* maxChild = nullptr;
    int64_t maxDepth = 0;
    for (const auto& child : ((Sgf*)sgf)->children) {
        int64_t childDepth = child->depth();
        if (childDepth > maxDepth) {
            maxDepth = childDepth;
            maxChild = child.get();
        }
    }

    // Recurse into the child with the maximum depth
    if (maxChild != nullptr) {
        traverseSgfHelper(maxChild);
    }
}

bool SgfCpp::getValid() const {
    return sgf != NULL;
}

int SgfCpp::getXSize() const {
    return _xSize;
}

int SgfCpp::getYSize() const {
    return _ySize;
}

unsigned long SgfCpp::getMovesSize() const {
    return moves.size();
}

bool SgfCpp::isValidMoveIndex(const int index) const {
    return (index >= 0) && (index < moves.size());
}

bool SgfCpp::isValidCommentIndex(const int index) const {
    return (index >= 0) && (index <= moves.size());
}

MoveCpp SgfCpp::getMoveAt(const int index) const {
    if (isValidMoveIndex(index)) {
        return moves[index];
    }
    return MoveCpp(LocCpp(), PlayerCpp::black);
}

string SgfCpp::getCommentAt(const int index) const {
    if (isValidCommentIndex(index)) {
        return comments[index];
    }
    return "";
}

RulesCpp SgfCpp::getRules() const {
    try {
        Rules rules = ((Sgf*)sgf)->getRulesOrFail();
        return RulesCpp(rules.koRule,
                        rules.scoringRule,
                        rules.taxRule,
                        rules.multiStoneSuicideLegal,
                        rules.hasButton,
                        rules.whiteHandicapBonusRule,
                        rules.friendlyPassOk,
                        rules.komi);
    } catch (std::exception &exception) {
        return RulesCpp(0, 0, 0, false, false, 0, false, 7.0);
    }
}

FinalPositionCpp::FinalPositionCpp(const string& black, const string& white)
    : _black(black), _white(white) {}

string FinalPositionCpp::getBlackStones() const {
    return _black;
}

string FinalPositionCpp::getWhiteStones() const {
    return _white;
}

FinalPositionCpp SgfCpp::getFinalPosition() const {
    if (sgf == NULL) {
        return FinalPositionCpp("", "");
    }
    // A board larger than the engine was compiled for would assert (abort, not a
    // catchable throw) when constructing the Board below. An imported SGF can
    // declare any size, so reject oversized boards up front and degrade to an
    // empty position rather than crashing.
    if (_xSize < 1 || _ySize < 1 || _xSize > Board::MAX_LEN || _ySize > Board::MAX_LEN) {
        return FinalPositionCpp("", "");
    }
    try {
        // The board's Zobrist tables must be initialized before any Board/
        // BoardHistory is built. The engine does this at GTP startup, but this
        // bridge can be called without a running engine (e.g. at import), so do
        // it here — idempotent, a no-op once initialized.
        Board::initHash();

        // Replay the main line with KataGo's own board rules: setup/handicap
        // stones (AB/AW) plus every move, captures resolved. Tolerant so a
        // malformed user-imported SGF throws (caught below) instead of asserting.
        // Note: SGFs with AB/AW placements AFTER the root node are unsupported by
        // CompactSgf and throw here -> caught -> empty position (graceful: same as
        // a game that was never opened; rare for app-exported SGFs).
        CompactSgf compact(*((const Sgf*)sgf));
        Rules rules = compact.getRulesOrFailAllowUnspecified(Rules::getTrompTaylorish());
        Board board;
        Player nextPla;
        BoardHistory hist;
        compact.setupBoardAndHistTolerant(rules, board, nextPla, hist,
                                          (int64_t)compact.moves.size(), true);

        string black;
        string white;
        for (int y = 0; y < board.y_size; y++) {
            for (int x = 0; x < board.x_size; x++) {
                Loc loc = Location::getLoc(x, y, board.x_size);
                Color c = board.colors[loc];
                if (c == C_BLACK) {
                    if (!black.empty()) black += " ";
                    black += Location::toString(loc, board.x_size, board.y_size);
                } else if (c == C_WHITE) {
                    if (!white.empty()) white += " ";
                    white += Location::toString(loc, board.x_size, board.y_size);
                }
            }
        }
        return FinalPositionCpp(black, white);
    } catch (...) {
        return FinalPositionCpp("", "");
    }
}
