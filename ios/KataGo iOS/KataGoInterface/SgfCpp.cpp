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
    this->player = player;
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
    return player;
}

SgfCpp::SgfCpp(const string& str) : sgf(nullptr), xSize(0), ySize(0) {
    try {
        sgf = Sgf::parse(str);
        if (sgf != NULL) {
            auto size = ((Sgf*)sgf)->getXYSize();
            xSize = size.x;
            ySize = size.y;
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
        const SgfNode* node = ((Sgf*)sgf)->nodes[i];

        // Extract move if present
        if (node->move.pla != C_EMPTY) {
            LocCpp locCpp;
            if ((node->move.x == COORD_MAX && node->move.y == COORD_MAX) ||
                (node->move.x == 19 && node->move.y == 19 && (xSize <= 19 || ySize <= 19))) {
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
            maxChild = child;
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
    return xSize;
}

int SgfCpp::getYSize() const {
    return ySize;
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
