//
//  GameLinkView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/11/9.
//

import SwiftUI
import SwiftData

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

            if let thumbnail = gameRecord.thumbnail,
               let uiImage = UIImage(data: thumbnail) {
                Spacer()
                Image(uiImage: uiImage)
                    .resizable()
                    .frame(width: thumbnailModel.width, height: thumbnailModel.height)
            }
        }
    }
}

extension Date {
    func timeIntervalSinceYesterday() -> TimeInterval {
        let yesterday = Date.now.addingTimeInterval(-24 * 60 * 60)
        let timeInterval = timeIntervalSince(yesterday)
        return timeInterval
    }

    func shortened() -> String {
        if timeIntervalSinceYesterday() > 0 {
            return formatted(date: .omitted, time: .shortened)
        } else {
            return formatted(date: .numeric, time: .omitted)
        }
    }
}
