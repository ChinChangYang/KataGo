//
//  AnalysisCommand.swift
//  KataGoAnalysisKit
//
//  Config-free GTP command-string builders for driving kata-analyze from any
//  process, including ones that cannot link the C++ bridge. KataGoUICore's
//  GtpCommandBuilder delegates here so each literal exists exactly once.
//

import Foundation

public enum AnalysisCommand {
    /// One continuous-analysis line. Engine-owning callers should precede this
    /// with a maxVisits reset when a human-profile gen-move may have run (see
    /// GtpCommandBuilder.continuousAnalyzeCommands for the sticky-maxVisits
    /// rationale); bridge-free consumers that never gen-move can use it bare.
    /// `ownership: false` drops the ownership grid from the reports — for
    /// consumers that render winrate only (the iOS Safari extension), where the
    /// grid is dead weight in both the message and the cached payload.
    public static func analyze(interval: Int, maxMoves: Int, ownership: Bool = true) -> String {
        let ownershipFlags = ownership ? "ownership true ownershipStdev true"
                                       : "ownership false"
        return "kata-analyze interval \(interval) maxmoves \(maxMoves) \(ownershipFlags) rootInfo true"
    }

    public static func boardSize(width: Int, height: Int) -> String {
        return "rectangular_boardsize \(width) \(height)"
    }

    /// Cancels a running kata-analyze / gen-move search.
    public static let stop = "stop"
}
