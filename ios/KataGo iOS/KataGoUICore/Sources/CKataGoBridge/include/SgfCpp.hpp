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
    PlayerCpp _player;
};

/// What an SGF root node does to a point before the first move: place a Black
/// stone (AB), place a White stone (AW), or clear the point (AE).
enum class PlacementColorCpp {
    empty,
    black,
    white
};

/// One root setup placement, with 0-based coordinates whose origin is the
/// TOP-LEFT (x right, y down) — the same convention as MoveCpp.
class PlacementCpp {
public:
    PlacementCpp(const int x, const int y, const PlacementColorCpp color);
    int getX() const SWIFT_COMPUTED_PROPERTY;
    int getY() const SWIFT_COMPUTED_PROPERTY;
    PlacementColorCpp getColor() const SWIFT_COMPUTED_PROPERTY;
private:
    int _x;
    int _y;
    PlacementColorCpp _color;
};

class RulesCpp {
public:
    RulesCpp(const int koRule,
             const int scoringRule,
             const int taxRule,
             const bool multiStoneSuicideLegal,
             const bool hasButton,
             const int whiteHandicapBonusRule,
             const bool friendlyPassOk,
             const float komi);
    int getKoRule() const SWIFT_COMPUTED_PROPERTY;
    int getScoringRule() const SWIFT_COMPUTED_PROPERTY;
    int getTaxRule() const SWIFT_COMPUTED_PROPERTY;
    bool getMultiStoneSuicideLegal() const SWIFT_COMPUTED_PROPERTY;
    bool getHasButton() const SWIFT_COMPUTED_PROPERTY;
    int getWhiteHandicapBonusRule() const SWIFT_COMPUTED_PROPERTY;
    bool getFriendlyPassOk() const SWIFT_COMPUTED_PROPERTY;
    float getKomi() const SWIFT_COMPUTED_PROPERTY;
private:
    int _koRule;
    int _scoringRule;
    int _taxRule;
    bool _multiStoneSuicideLegal;
    bool _hasButton;
    int _whiteHandicapBonusRule;
    bool _friendlyPassOk;
    float _komi;
};

class FinalPositionCpp {
public:
    FinalPositionCpp(const string& black, const string& white);
    string getBlackStones() const SWIFT_COMPUTED_PROPERTY;
    string getWhiteStones() const SWIFT_COMPUTED_PROPERTY;
private:
    string _black;
    string _white;
};

/// One board position along an SGF's main line: the stones standing after a
/// given number of moves (captures resolved) plus the vertex of the move that
/// produced it, all as GTP vertex strings ("Q16", or "pass"/"" when there is no
/// highlightable last move). Used to build one animation frame per move for GIF
/// export without running the engine.
class GifFrameCpp {
public:
    GifFrameCpp(const string& black, const string& white, const string& lastMove);
    string getBlackStones() const SWIFT_COMPUTED_PROPERTY;
    string getWhiteStones() const SWIFT_COMPUTED_PROPERTY;
    string getLastMove() const SWIFT_COMPUTED_PROPERTY;
private:
    string _black;
    string _white;
    string _lastMove;
};

class SgfCpp {
public:
    SgfCpp(const string& str);
    bool getValid() const SWIFT_COMPUTED_PROPERTY;
    int getXSize() const SWIFT_COMPUTED_PROPERTY;
    int getYSize() const SWIFT_COMPUTED_PROPERTY;
    unsigned long getMovesSize() const SWIFT_COMPUTED_PROPERTY;
    /// The root node's AB/AW/AE placements, expanded from compressed point
    /// ranges, in the order the engine accumulates them (AB, then AW, then
    /// AE) — the position the engine is set up with before any move is
    /// played. Empty for an invalid SGF or an undecodable placement list.
    /// Placements on nodes AFTER the root are deliberately not reported: the
    /// engine's own CompactSgf refuses such records outright.
    unsigned long getPlacementsSize() const SWIFT_COMPUTED_PROPERTY;
    PlacementCpp getPlacementAt(const int index) const;
    bool isValidMoveIndex(const int index) const;
    bool isValidCommentIndex(const int index) const;
    MoveCpp getMoveAt(const int index) const;
    string getCommentAt(const int index) const;
    RulesCpp getRules() const;
    FinalPositionCpp getFinalPosition() const;
    /// The board position after `moveCount` moves of the main line (0 = the
    /// starting/handicap position, values above the move count are clamped to
    /// the final position). Replays with KataGo's own rules, so captures are
    /// resolved; engine-free. See GifFrameCpp.
    GifFrameCpp getFrameAt(const int moveCount) const;
private:
    void* sgf;
    int _xSize;
    int _ySize;
    vector<MoveCpp> moves;
    vector<PlacementCpp> placements;
    vector<string> comments;
    void traverseSgf(const void* sgf);
    void collectPlacements(const void* sgf);
    void traverseSgfHelper(const void* sgf);
    /// Shared main-line replay backing both getFinalPosition and getFrameAt.
    /// `turnIdx < 0` (or beyond the move count) means the final position.
    GifFrameCpp buildFrame(long long turnIdx) const;
};

#endif /* SgfCpp_hpp */
