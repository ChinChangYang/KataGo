//
//  WinrateBarView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/7/1.
//

import SwiftUI

struct WinrateBarView: View {
    @Environment(Winrate.self) var rootWinrate
    @Environment(Score.self) var rootScore
    let dimensions: Dimensions

    var body: some View {
        let width = dimensions.squareLengthDiv2 - dimensions.squareLengthDiv8
        let positionXBegin = dimensions.gobanStartX - width + dimensions.squareLengthDiv8 + dimensions.squareLengthDiv16
        let positionXEnd = positionXBegin + width
        let positionX = (positionXBegin + positionXEnd) / 2
        let barHeight = dimensions.gobanHeight
        let whiteBarHeight = barHeight * CGFloat(rootWinrate.white)
        let blackBarHeight = barHeight - whiteBarHeight
        let whiteBarPositionYBegin = dimensions.gobanStartY
        let whiteBarPositionYEnd = whiteBarPositionYBegin + whiteBarHeight
        let blackBarPositionYBegin = whiteBarPositionYEnd
        let blackBarPositionYEnd = blackBarPositionYBegin + blackBarHeight
        let whiteBarPositionY = (whiteBarPositionYBegin + whiteBarPositionYEnd) / 2
        let blackBarPositionY = (blackBarPositionYBegin + blackBarPositionYEnd) / 2
        let barCenterY = dimensions.gobanStartY + (barHeight / 2)
        let scoreTextValue = abs(lround(Double(rootScore.black)))

        ZStack {
            Rectangle()
                .frame(width: width, height: whiteBarHeight)
                .foregroundStyle(.white)
                .position(x: positionX, y: whiteBarPositionY)

            Rectangle()
                .frame(width: width, height: blackBarHeight)
                .foregroundStyle(.black)
                .position(x: positionX, y: blackBarPositionY)

            Text(String(format: "%d", scoreTextValue))
                .font(.system(size: (scoreTextValue < 10) ? 14 : 500, design: .monospaced))
                .minimumScaleFactor(0.01)
                .foregroundStyle(.gray)
                .frame(width: width)
                .position(x: positionX, y: barCenterY)
        }
    }
}

#Preview {
    let rootWinrate = Winrate()
    let rootScore = Score()

    return ZStack {
        Rectangle()
            .foregroundStyle(.brown)

        GeometryReader { geometry in
            let dimensions = Dimensions(size: geometry.size,
                                        width: 2,
                                        height: 2,
                                        showCoordinate: false)
            BoardLineView(dimensions: dimensions, showPass: true, verticalFlip: false)
            WinrateBarView(dimensions: dimensions)
        }
        .environment(rootWinrate)
        .environment(rootScore)
    }
}
