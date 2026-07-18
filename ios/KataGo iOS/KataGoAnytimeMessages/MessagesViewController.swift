//
//  MessagesViewController.swift
//  KataGoAnytimeMessages
//
//  The iMessage extension shell. State is derived from the conversation's
//  selected message (the tapped bubble): its URL carries the whole game, so
//  the extension is stateless between activations. Turn enforcement is the
//  alternation gate — the board is view-only when the local participant sent
//  the last game message. Sending a move stages an MSMessage on the SAME
//  MSSession into the compose field; Messages' send arrow is the final
//  confirm.
//

import Messages
import SwiftUI
import GoRulesKit

@objc(MessagesViewController)
final class MessagesViewController: MSMessagesAppViewController {
    private let model = ExtensionModel()
    private var hostingController: UIHostingController<MessagesRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.actions = ExtensionActions(
            stage: { [weak self] game in self?.stage(game) },
            openInApp: { [weak self] game in self?.openInApp(game) },
            requestExpanded: { [weak self] in
                guard let self, self.presentationStyle != .expanded else { return }
                self.requestPresentationStyle(.expanded)
            })
        let host = UIHostingController(rootView: MessagesRootView(model: model))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    // MARK: - Conversation lifecycle

    override func willBecomeActive(with conversation: MSConversation) {
        model.refresh(from: conversation, presentationStyle: presentationStyle)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        // A new bubble landed while we're open (closes the simultaneous-send
        // race): rebuild from the conversation.
        model.refresh(from: conversation, presentationStyle: presentationStyle)
    }

    override func didStartSending(_ message: MSMessage, conversation: MSConversation) {
        // Our staged move went out: the sent message is now the latest state.
        model.refresh(from: conversation, presentationStyle: presentationStyle)
    }

    override func didCancelSending(_ message: MSMessage, conversation: MSConversation) {
        model.refresh(from: conversation, presentationStyle: presentationStyle)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        model.presentationStyle = presentationStyle == .expanded ? .expanded : .compact
    }

    // MARK: - Compose

    /// Builds the bubble for `game` and stages it into the compose field on
    /// the current session (or a fresh one for a new game).
    private func stage(_ game: MessageGame) {
        guard let conversation = activeConversation else { return }
        let session = conversation.selectedMessage?.session ?? MSSession()
        let message = MSMessage(session: session)
        message.url = MessageGameCodec.url(for: game)
        let layout = MSMessageTemplateLayout()
        layout.image = BubbleRenderer.image(for: game)
        layout.caption = BubbleRenderer.caption(for: game)
        layout.subcaption = BubbleRenderer.subcaption(for: game)
        message.layout = layout
        message.summaryText = BubbleRenderer.caption(for: game)
        conversation.insert(message)
        model.noteStaged(game)
    }

    /// Open-in-app hand-off: spool the SGF into the App Group container and
    /// deep-link the main app to import it.
    private func openInApp(_ game: MessageGame) {
        guard let url = AppHandoff.spoolAndDeepLink(game) else { return }
        extensionContext?.open(url)
    }
}
