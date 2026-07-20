//
//  ScoreLeadText.swift
//  KataGoUICore
//
//  Pure formatting for a Black-perspective score lead shown as text (the
//  tvOS panels' "Score" line). Kept in the package so the evenness rule is
//  unit-testable from the iOS test host (TV-target code is unreachable from
//  tests).
//

import Foundation

public enum ScoreLeadText {
    /// A lead is "even" when the one-decimal display would read 0.0 — the
    /// same granularity the label shows, either side of zero.
    public static func isEven(blackScore: Float) -> Bool {
        magnitudeText(blackScore) == "0.0"
    }

    /// "B+2.3" / "W+0.5" from Black's perspective, or "Even" when the lead
    /// would display as 0.0. A dead-even position must not be attributed to
    /// a side (a plain `>= 0` sign check rendered a drawn game as "B+0.0").
    public static func sideAnnotated(blackScore: Float) -> String {
        if isEven(blackScore: blackScore) { return "Even" }
        return (blackScore > 0 ? "B+" : "W+") + magnitudeText(blackScore)
    }

    private static func magnitudeText(_ blackScore: Float) -> String {
        String(format: "%.1f", abs(blackScore))
    }
}
