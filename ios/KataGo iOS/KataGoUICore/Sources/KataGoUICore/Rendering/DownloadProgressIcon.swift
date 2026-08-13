//
//  DownloadProgressIcon.swift
//  KataGo Anytime
//
//  The spinning KataGo icon shown while a catalog asset downloads. One
//  definition, three call sites (iOS networks, iOS opening books, visionOS
//  networks) — before this it was two hand-copied modifier chains that had
//  already drifted apart by one `.frame`.
//

import SwiftUI

public struct DownloadProgressIcon: View {

    private let icon: Image
    private let progress: Double

    /// - Parameters:
    ///   - icon: taken un-resized, and as an `Image` rather than a name,
    ///     because `.loadingIcon` is an asset-catalog symbol that exists in
    ///     each app target's own catalog and cannot be vended by the package.
    ///   - progress: 0...1. A non-finite value rotates by nothing rather than
    ///     handing SwiftUI a NaN angle, which drops the view entirely.
    public init(icon: Image, progress: Double) {
        self.icon = icon
        self.progress = progress
    }

    public var body: some View {
        icon
            .resizable()
            .scaledToFit()
            .clipShape(.circle)
            .rotationEffect(.degrees(progress.isFinite ? progress * 360 : 0))
    }
}
