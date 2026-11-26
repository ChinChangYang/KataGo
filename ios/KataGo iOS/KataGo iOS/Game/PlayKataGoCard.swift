//
//  PlayKataGoCard.swift
//  KataGo Anytime
//
//  The start card: what a fresh board shows where its score chart would be.
//
//  A game with no moves has no chart to draw — the pane above the board is a
//  set of empty axes, on the one screen every new user is guaranteed to see.
//  That space says what the app is for instead, and opens the New Game sheet.
//  It leaves by itself: the first stone, or a side handed to the engine, makes
//  the game no longer fresh (`FreshBoard`) and the chart takes its place back.
//

import SwiftUI
import KataGoUICore

struct PlayKataGoCard: View {
    @Environment(TopUIState.self) private var topUIState

    var body: some View {
        Button {
            topUIState.presentingNewGame = true
        } label: {
            HStack(spacing: 14) {
                stones

                VStack(alignment: .leading, spacing: 2) {
                    Text("Play KataGo")
                        .font(.title3.bold())

                    Text("Choose an opponent, from 25 kyu to full strength.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(),
                     in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityIdentifier("PlayKataGoCard")
    }

    /// A black and a white stone, the smallest picture that says "a game".
    private var stones: some View {
        ZStack {
            Circle()
                .fill(.black)
                // A rim, or the black stone is lost on a dark card.
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: 30, height: 30)
                .offset(x: -9)
            Circle()
                .fill(.white)
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .offset(x: 9)
        }
        .frame(width: 50, height: 34)
        .accessibilityHidden(true)
    }
}

#Preview {
    PlayKataGoCard()
        .padding()
        .environment(TopUIState())
}
