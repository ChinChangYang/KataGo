//
//  GameLinkView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/11/9.
//

import SwiftUI
import SwiftData
import KataGoUICore

struct GameLinkView: View {
    let gameRecord: GameRecord
    @Environment(GobanState.self) var gobanState

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gameRecord.name)
                    .font(.headline)
                    .lineLimit(1)

                // The note on the move this game is parked on — the same move
                // the thumbnail beside it draws. Absent for a game nobody has
                // annotated here, and the row simply loses the line rather than
                // reserving a blank one.
                if let comment = gameRecord.libraryRowComment {
                    Text(comment)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(gameRecord.lastModificationDate?.shortened() ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // No size means the user turned thumbnails off, and the row does no
            // picture work at all: `RecordBoardPreviewSource` replays the
            // record's SGF, so it must not be reached from here. The spacer
            // lives inside the branch on purpose — with no trailing picture the
            // text SHOULD sit flush against the leading edge, which is the whole
            // point of turning them off. (It was unconditional while every row
            // drew a board; do not restore that.)
            if let side = ThumbnailMetrics.side(for: gobanState.thumbnailSize) {
                Spacer()

                // The picture is derived from the record, never captured from the
                // screen (ADR 0014), so this row cannot draw another game's board.
                if let preview = RecordBoardPreviewSource.preview(for: gameRecord) {
                    ReportBoardView(width: preview.width,
                                    height: preview.height,
                                    blackVertices: preview.blackVertices,
                                    whiteVertices: preview.whiteVertices,
                                    overlay: .none,
                                    lastMoveVertex: preview.lastMoveVertex,
                                    isClassicStoneStyle: gobanState.isClassicStoneStyle,
                                    showCoordinate: false,
                                    verticalFlip: gobanState.verticalFlip)
                    .frame(width: side, height: side)
                    // `ReportBoardView` installs its tap recognizer unconditionally —
                    // the nil-callback guard keeps the CALLBACK inert, not the
                    // gesture. Left hit-testable it swallows the NavigationLink's
                    // tap and the row stops opening its game.
                    .allowsHitTesting(false)
                    // The row already announces the game by name; a board with no
                    // label would only add noise for VoiceOver.
                    .accessibilityHidden(true)
                } else {
                    // The record's SGF could not be read. Say so with the same
                    // symbol the Mac uses, rather than a blank the eye reads as a
                    // fine game.
                    Image(systemName: "square.grid.3x3")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: side, height: side)
                        .accessibilityLabel("Unreadable game record")
                }
            }
        }
    }
}
