//
//  SgfCpp.hpp
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/8.
//

#ifndef SgfCpp_hpp
#define SgfCpp_hpp

#include <swift/bridging>
#include <string>
#include <vector>

using namespace std;

class LocCpp {
public:
    LocCpp();
    LocCpp(const int x, const int y);
    LocCpp(const LocCpp& loc);
    int getX() const SWIFT_COMPUTED_PROPERTY;
    int getY() const SWIFT_COMPUTED_PROPERTY;
    bool getPass() const SWIFT_COMPUTED_PROPERTY;
private:
    int x;
    int y;
    bool pass;
};

enum class PlayerCpp {
    black,
    white
};

class MoveCpp {
public:
    MoveCpp(const LocCpp& loc, const PlayerCpp player);
    int getX() const SWIFT_COMPUTED_PROPERTY;
    int getY() const SWIFT_COMPUTED_PROPERTY;
    bool getPass() const SWIFT_COMPUTED_PROPERTY;
    PlayerCpp getPlayer() const SWIFT_COMPUTED_PROPERTY;
private:
    LocCpp loc;
    PlayerCpp player;
};

class SgfCpp {
public:
    SgfCpp(const string& str);
    bool getValid() const SWIFT_COMPUTED_PROPERTY;
    int getXSize() const SWIFT_COMPUTED_PROPERTY;
    int getYSize() const SWIFT_COMPUTED_PROPERTY;
    unsigned long getMovesSize() const SWIFT_COMPUTED_PROPERTY;
    bool isValidMoveIndex(const int index) const;
    bool isValidCommentIndex(const int index) const;
    MoveCpp getMoveAt(const int index) const;
    string getCommentAt(const int index) const;
private:
    void* sgf;
    int xSize;
    int ySize;
    vector<MoveCpp> moves;
    vector<string> comments;
    void traverseSgf(const void* sgf);
    void traverseSgfHelper(const void* sgf);
};

#endif /* SgfCpp_hpp */
