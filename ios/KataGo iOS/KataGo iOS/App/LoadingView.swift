//
//  LoadingView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/15.
//

import SwiftUI
import KataGoUICore

@MainActor
struct LoadingView: View {
    @State var degreesRotating = 0.0
    @State var text = ""
    @State var textOffset = 0
    @State var animationSpeed = 0.05
    @State var animationCount = 0
    @Binding var version: String?
    @Environment(EngineLaunchStatus.self) private var launchStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxAnimationCount = 5

    var body: some View {
        VStack {
            VStack {
                Text(text)
                    .font(.largeTitle)
                    .bold()
                    .contentTransition(.numericText())
                    .onAppear {
                        appearAction()
                    }
                    .padding()
                    .accessibilityIdentifier("loadingText")

                if let line = secondaryLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Image(.loadingIcon)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 512, maxHeight: 512)
                .clipShape(.circle)
                .rotationEffect(.degrees(degreesRotating))
                .shadow(radius: 8, x: 16, y: 16)
                .onAppear {
                    startSpin()
                }
                .onTapGesture {
                    tapGestureAction()
                }
        }
    }

    private func appearAction() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task {
                await MainActor.run {
                    withAnimation {
                        let fullText = version != nil ? "Entering..." : "Loading..."
                        let startIndex = fullText.firstIndex(of: ".") ?? fullText.startIndex
                        let index = fullText.index(startIndex, offsetBy: textOffset)
                        text = String(fullText[..<index])
                        textOffset = (textOffset + 1) % 4
                    }
                }
            }
        }
    }

    /// Continuous rotation of the loading icon: a slow 20 s turn that repeats
    /// until the view goes away (so the icon never freezes during a long
    /// first-launch Core ML compile). Pinned when Reduce Motion is on.
    private func startSpin() {
        guard !reduceMotion else { return }
        degreesRotating = 0
        withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
            degreesRotating = 360
        }
    }

    private func tapGestureAction() {
        guard !reduceMotion else { return }
        if animationCount < LoadingView.maxAnimationCount {
            degreesRotating = 0
            withAnimation(.bouncy(duration: 1)
                .speed(animationSpeed)) {
                    degreesRotating = 360
                    animationCount = animationCount + 1
                } completion: {
                    animationCount = animationCount - 1
                    // Hand back to the continuous spin once the last queued
                    // bounce finishes (otherwise the icon stops at 360°).
                    if animationCount == 0 {
                        startSpin()
                    }
                }
        }
    }

    /// Core ML compile caption. Shown only while a compile is genuinely
    /// running — a cache hit says nothing — and it makes no claim about
    /// whether the compile will recur, because it would be false: see ADR 0007.
    private var secondaryLine: String? {
        launchStatus.isCompiling ? "Compiling Core ML model…" : nil
    }
}
