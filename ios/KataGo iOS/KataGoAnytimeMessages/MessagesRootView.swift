//
//  MessagesRootView.swift
//  KataGoAnytimeMessages
//
//  Screen routing for the extension. Everything derives from the selected
//  bubble: no bubble → new-game setup; a game bubble → the board, view-only
//  when the local participant sent it (alternation turn gate); a bubble that
//  fails to replay → invalid-game card.
//

import Messages
import Observation
import SwiftUI
import GoRulesKit

struct ExtensionActions {
    var stage: (MessageGame) -> Void
    var openInApp: (MessageGame) -> Void
    var requestExpanded: () -> Void
}

enum ExtensionScreen {
    /// Setup card (drawer launch or rematch).
    case newGame
    /// A decoded game. `isLocalTurn` is the alternation gate;
    /// `staged` means our reply sits in the compose field awaiting send.
    case game(MessageGame, isLocalTurn: Bool, staged: Bool)
    /// The bubble's payload did not replay legally.
    case invalid
}

enum ExtensionPresentation {
    case compact
    case expanded
}

@Observable
final class ExtensionModel {
    var screen: ExtensionScreen = .newGame
    var presentationStyle: ExtensionPresentation = .compact
    @ObservationIgnored var actions = ExtensionActions(
        stage: { _ in }, openInApp: { _ in }, requestExpanded: {})

    /// Rebuilds the screen from a message. `selecting` overrides the
    /// conversation's selected message — didStartSending passes the message
    /// that just went out, whose sender is the LOCAL participant, so the
    /// screen flips straight to the view-only waiting state.
    func refresh(from conversation: MSConversation,
                 selecting overrideMessage: MSMessage? = nil,
                 presentationStyle style: MSMessagesAppPresentationStyle) {
        presentationStyle = style == .expanded ? .expanded : .compact
        guard let message = overrideMessage ?? conversation.selectedMessage,
              let url = message.url, MessageGameCodec.isGameURL(url) else {
            screen = .newGame
            return
        }
        guard let decoded = try? MessageGameCodec.decode(url) else {
            screen = .invalid
            return
        }
        let isLocalTurn = message.senderParticipantIdentifier != conversation.localParticipantIdentifier
        screen = .game(decoded, isLocalTurn: isLocalTurn, staged: false)
    }

    /// Our reply is in the compose field: keep showing it, view-only, until
    /// Messages sends it (didStartSending) or the user deletes it
    /// (didCancelSending) — both trigger a refresh.
    func noteStaged(_ game: MessageGame) {
        screen = .game(game, isLocalTurn: false, staged: true)
    }
}

struct MessagesRootView: View {
    @Bindable var model: ExtensionModel

    var body: some View {
        switch model.presentationStyle {
        case .compact:
            CompactSummaryView(model: model)
        case .expanded:
            expandedBody
        }
    }

    @ViewBuilder
    private var expandedBody: some View {
        switch model.screen {
        case .newGame:
            SetupCardView { setup in
                startGame(setup)
            }
        case .game(let game, let isLocalTurn, let staged):
            GameScreenView(
                message: game,
                isLocalTurn: isLocalTurn,
                staged: staged,
                actions: model.actions)
        case .invalid:
            ContentUnavailableView(
                "Invalid game",
                systemImage: "exclamationmark.triangle",
                description: Text("This message could not be read as a valid Go game."))
        }
    }

    private func startGame(_ setup: GameSetup) {
        guard let game = try? GoGame(
            width: setup.width, height: setup.height,
            rules: setup.rules, handicap: setup.handicap) else { return }
        let message = MessageGame(game: game, creatorColor: setup.creatorColor)
        if game.toMove == setup.creatorColor {
            // Creator moves first: open the board to place the first stone.
            model.screen = .game(message, isLocalTurn: true, staged: false)
        } else {
            // Opponent moves first (creator took White, or gave handicap):
            // the setup itself is the invitation bubble.
            model.actions.stage(message)
        }
    }
}

/// The compact drawer presentation: too small for a board, so summarize and
/// hand off to the expanded sheet.
struct CompactSummaryView: View {
    @Bindable var model: ExtensionModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(summary)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button(buttonTitle) {
                model.actions.requestExpanded()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summary: String {
        switch model.screen {
        case .newGame: "Start a game of Go"
        case .game(let game, let isLocalTurn, _):
            if case .finished = game.game.phase {
                BubbleRenderer.caption(for: game)
            } else {
                BubbleRenderer.caption(for: game) + (isLocalTurn ? " — your move" : "")
            }
        case .invalid: "Invalid game"
        }
    }

    private var buttonTitle: String {
        switch model.screen {
        case .newGame: "New Game"
        case .game: "Open Board"
        case .invalid: "Details"
        }
    }
}
