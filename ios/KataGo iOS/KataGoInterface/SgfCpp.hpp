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
    RulesCpp getRules() const;
private:
    void* sgf;
    int _xSize;
    int _ySize;
    vector<MoveCpp> moves;
    vector<string> comments;
    void traverseSgf(const void* sgf);
    void traverseSgfHelper(const void* sgf);
};

#endif /* SgfCpp_hpp */
