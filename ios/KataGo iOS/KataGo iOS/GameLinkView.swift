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

    var body: some View {
        VStack(alignment: .leading) {
            Text(gameRecord.name)
                .font(.headline)
            HStack {
                Text(gameRecord.lastModificationDate?.shortened() ?? "")
                Text(gameRecord.comments?[0] ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
