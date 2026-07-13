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

            if let image = gameRecord.image {
                    Spacer()

                    image
                    .resizable()
                    .frame(width: thumbnailModel.width, height: thumbnailModel.height)
            }
        }
    }
}
