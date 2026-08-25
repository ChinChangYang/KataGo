//
//  DeepLinkRouter.swift
//  KataGoUICore
//
//  Captures a `katago-anytime://open-game` deep link at the root of the
//  iOS/visionOS scene so it survives a cold launch.
//

import SwiftUI

/// A board image opened WITH the app (Files "Open in" / share sheet / Finder
/// "Open With"), latched at the root `.onOpenURL` so it survives a cold launch
/// until `GameSplitView` mounts and can present the photo-recognition sheet.
public struct PendingImageImport: Equatable {
    public let imageData: Data
    public let suggestedName: String
    public init(imageData: Data, suggestedName: String) {
        self.imageData = imageData
        self.suggestedName = suggestedName
    }
}

/// Holds the game id of a pending `open-game` deep link.
///
/// The root `.onOpenURL` (mounted from the first frame, above the model-picker
/// sheet and independent of the engine) stores the requested id here.
/// `ContentView.seedInitialGame` reads it to pick the initial game, and a warm
/// app applies it via `GameSplitView`'s `.onChange`. This closes the gap where a
/// cold-launch deep link was delivered before `GameSplitView`'s own
/// `.onOpenURL` existed and was lost to the default most-recent selection.
/// Nothing here waits for the engine: the linked game is drawn from its record
/// at once and fed to the engine when the handshake completes (ADR 0008).
@Observable
public class DeepLinkRouter {
    public var pendingGameID: UUID?

    /// A pending "listen to this game" request from the Listen App Intents,
    /// drained at the iOS app root into a Listening Session. Separate from
    /// `pendingGameID` on purpose: listening never moves any board, so it
    /// must not ride the open-game selection path.
    public var pendingListenGameID: UUID?

    /// A board image opened WITH the app, latched by the root `.onOpenURL`.
    /// The bytes are read AT RECEIPT rather than latching the URL: the URL's
    /// sandbox (security-scoped) extension is not guaranteed to survive until
    /// `GameSplitView` mounts on a cold launch, so a URL latch could go stale —
    /// a `Data` latch cannot. `GameSplitView`'s
    /// `.onChange(of:initial:)` drain routes it into the existing
    /// photo-recognition import (recognition → confirm sheet → new game).
    public var pendingImageImport: PendingImageImport?

    public init() {}

    /// Process-wide instance shared between the iOS app (environment-injected
    /// at the root) and the Shortcuts "Open …" App Intents, which cannot reach
    /// a `@State`-owned router. The intents write `pendingGameID` here directly:
    /// returning `OpenURLIntent` with the custom `katago-anytime` scheme is
    /// refused by the system ("launch is prohibited" — only universal links are
    /// supported), so they route in-process instead. visionOS keeps its own
    /// per-view instance and does not use this.
    @MainActor public static let shared = DeepLinkRouter()
}
