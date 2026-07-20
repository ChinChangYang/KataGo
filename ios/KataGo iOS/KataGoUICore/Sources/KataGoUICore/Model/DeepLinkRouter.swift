//
//  DeepLinkRouter.swift
//  KataGoUICore
//
//  Captures a `katago-anytime://open-game` deep link at the root of the
//  iOS/visionOS scene so it survives a cold launch.
//

import SwiftUI

/// Holds the game id of a pending `open-game` deep link.
///
/// The root `.onOpenURL` (mounted from the first frame, even while the model
/// picker or loading screen is showing) stores the requested id here.
/// `ContentView.initializationTask` reads it to pick the initial game, and a
/// warm app applies it via `GameSplitView`'s `.onChange`. This closes the gap
/// where a cold-launch deep link was delivered before `GameSplitView`'s own
/// `.onOpenURL` existed and was lost to the default most-recent selection.
@Observable
public class DeepLinkRouter {
    public var pendingGameID: UUID?
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
