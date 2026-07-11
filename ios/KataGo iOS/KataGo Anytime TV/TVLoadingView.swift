//
//  TVLoadingView.swift
//  KataGo Anytime TV
//
//  Engine-loading screen matching the iOS LoadingView design: a ticking
//  "Loading engine…" headline, a secondary Core ML compile-status line
//  (EngineLaunchStatus), and the spinning circular KataGo icon. tvOS
//  adaptations: the rotation repeats forever (a first-launch Core ML
//  compile outlasts iOS's single 20 s turn), there is no tap-to-spin
//  (nothing focusable on the remote), the secondary line is .title3 for
//  10-foot legibility, and Reduce Motion pins the icon.
//

import SwiftUI
import KataGoUICore

struct TVLoadingView: View {
    /// Headline base text; the view ticks trailing dots onto it.
    var caption: String

    @State private var degreesRotating = 0.0
    @State private var dotCount = 0
    @Environment(EngineLaunchStatus.self) private var launchStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Text(caption + String(repeating: ".", count: dotCount))
                .font(.largeTitle)
                .bold()
                .contentTransition(.numericText())
                .padding()

            if let line = secondaryLine {
                Text(line)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Image(.loadingIcon)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 512, maxHeight: 512)
                .clipShape(.circle)
                .rotationEffect(.degrees(degreesRotating))
                .shadow(radius: 8, x: 16, y: 16)
                .padding(.top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var secondaryLine: String? {
        switch launchStatus.phase {
        case .compilingMissFirstLaunch: "Compiling Core ML model — first launch only"
        case .awaitingPrecompile:       "Finishing Core ML compile…"
        case .idle:                     nil
        @unknown default:               nil
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Loading view") {
    TVLoadingView(caption: "Loading engine")
        .environment(EngineLaunchStatus())
}

#Preview("Loading view — compiling") {
    let status = EngineLaunchStatus()
    let _ = status.phase = .compilingMissFirstLaunch
    TVLoadingView(caption: "Loading engine")
        .environment(status)
}
#endif
