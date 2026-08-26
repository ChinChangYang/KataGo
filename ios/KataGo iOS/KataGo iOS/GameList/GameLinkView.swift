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
    @Environment(ThumbnailModel.self) var thumbnailModel
    @Environment(GobanState.self) var gobanState

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(gameRecord.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack {
                    Text(gameRecord.lastModificationDate?.shortened() ?? "")
                    Text(gameRecord.comments?[0] ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Unconditional: the board is drawn for EVERY row, so the spacer
            // that pushes it to the trailing edge cannot live inside a
            // conditional. It used to, and a row without a picture collapsed to
            // leading-aligned — which would now be every row in a library where
            // some games are unreadable.
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
                .frame(width: thumbnailModel.width, height: thumbnailModel.height)
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
                    .frame(width: thumbnailModel.width, height: thumbnailModel.height)
                    .accessibilityLabel("Unreadable game record")
            }
        }
    }
}
