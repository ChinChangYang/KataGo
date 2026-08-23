//
//  EngineLoadingView.swift
//  KataGoUICore
//
//  Shared pre-engine-ready loading screen: a ticking "Loading…" headline, an
//  optional Core ML compile-status caption (`EngineLaunchStatus`), and a slowly
//  spinning circular app icon (pinned when Reduce Motion is on). Extracted from
//  the byte-identical macOS `EngineLaunchStatusView` and tvOS `TVLoadingView` so
//  the dot ticker, rotation, and caption logic live in ONE place; each platform
//  wraps this with its own caption text, secondary font, icon asset, and icon
//  sizing.
//
//  The iOS `LoadingView` is intentionally NOT built on this: it has a
//  Timer-typed, version-aware headline ("Entering…" vs "Loading…"), a
//  tap-to-spin easter egg, and a UI-test-referenced accessibility identifier
//  that genuinely diverge.
//

import SwiftUI

public struct EngineLoadingView: View {
    /// How the spinning icon is sized within the available space.
    public enum IconSizing: Sendable {
        /// A fixed maximum square (points) — e.g. `512` on tvOS.
        case fixed(CGFloat)
        /// A fraction of the smaller side of the available space — e.g. `0.8` on
        /// macOS, so the icon scales with the board pane.
        case proportional(CGFloat)
    }

    private let caption: String
    private let secondaryFont: Font
    private let icon: Image
    private let iconSizing: IconSizing
    private let status: EngineLaunchStatus

    @State private var degreesRotating = 0.0
    @State private var dotCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - caption: Headline base text; the view ticks trailing dots onto it.
    ///   - secondaryFont: Font for the Core ML compile-status caption (`.caption`
    ///     for a window pane, `.title3` for 10-foot tvOS legibility).
    ///   - icon: The spinning image. Pass it WITHOUT `.resizable()` — this view
    ///     applies `.resizable().scaledToFit()`. Passed per target because the
    ///     `.loadingIcon` asset lives in each app target's catalog, not the package.
    ///   - iconSizing: `.fixed` or `.proportional` sizing strategy.
    ///   - status: Drives the secondary compile-status line; read inside `body`
    ///     so `@Observable` updates re-render the caption.
    public init(caption: String,
                secondaryFont: Font = .caption,
                icon: Image,
                iconSizing: IconSizing,
                status: EngineLaunchStatus) {
        self.caption = caption
        self.secondaryFont = secondaryFont
        self.icon = icon
        self.iconSizing = iconSizing
        self.status = status
    }

    public var body: some View {
        GeometryReader { geo in
            VStack {
                Text(caption + String(repeating: ".", count: dotCount))
                    .font(.largeTitle)
                    .bold()
                    .contentTransition(.numericText())
                    .padding()

                if let line = secondaryLine {
                    Text(line)
                        .font(secondaryFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                icon
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: iconDiameter(in: geo.size),
                           maxHeight: iconDiameter(in: geo.size))
                    .clipShape(.circle)
                    .rotationEffect(.degrees(degreesRotating))
                    .shadow(radius: 8, x: 16, y: 16)
                    .padding(.top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                withAnimation {
                    dotCount = (dotCount + 1) % 4
                }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                degreesRotating = 360
            }
        }
    }

    /// Diameter for the spinning icon per the sizing strategy. `scaledToFit`
    /// keeps the image from exceeding this box.
    private func iconDiameter(in size: CGSize) -> CGFloat {
        switch iconSizing {
        case .fixed(let dimension):
            return dimension
        case .proportional(let fraction):
            return min(size.width, size.height) * fraction
        }
    }

    /// Core ML compile caption. `nil` unless a compile is genuinely running —
    /// on the MLX/GPU path, and on any cache hit, the ticking headline already
    /// reads "Loading…". It makes no claim about whether the compile will
    /// recur, because it would be false: see ADR 0007.
    ///
    /// The string itself lives on `EngineLaunchStatus`, shared with the iOS
    /// launch screen and the inline `EngineStatusView`, so the three cannot
    /// drift apart.
    private var secondaryLine: String? {
        status.compileCaption
    }
}
