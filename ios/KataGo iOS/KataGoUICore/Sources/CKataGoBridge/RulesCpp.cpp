//
//  RulesCpp.cpp
//  KataGoInterface
//
//  Created by Chin-Chang Yang on 2025/5/10.
//

#include "SgfCpp.hpp"

RulesCpp::RulesCpp(const int koRule,
                   const int scoringRule,
                   const int taxRule,
                   const bool multiStoneSuicideLegal,
                   const bool hasButton,
                   const int whiteHandicapBonusRule,
                   const bool friendlyPassOk,
                   const float komi) :
_koRule(koRule),
_scoringRule(scoringRule),
_taxRule(taxRule),
_multiStoneSuicideLegal(multiStoneSuicideLegal),
_hasButton(hasButton),
_whiteHandicapBonusRule(whiteHandicapBonusRule),
_friendlyPassOk(friendlyPassOk),
_komi(komi) {
}

int RulesCpp::getKoRule() const {
    return _koRule;
}

int RulesCpp::getScoringRule() const {
    return _scoringRule;
}

int RulesCpp::getTaxRule() const {
    return _taxRule;
}

bool RulesCpp::getMultiStoneSuicideLegal() const {
    return _multiStoneSuicideLegal;
}

bool RulesCpp::getHasButton() const {
    return _hasButton;
}

int RulesCpp::getWhiteHandicapBonusRule() const {
    return _whiteHandicapBonusRule;
}

bool RulesCpp::getFriendlyPassOk() const {
    return _friendlyPassOk;
}

float RulesCpp::getKomi() const {
    return _komi;
}
