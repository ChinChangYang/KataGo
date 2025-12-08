//
//  LoadingView.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/15.
//

import SwiftUI

@MainActor
struct LoadingView: View {
    @State var degreesRotating = 0.0
    @State var text = ""
    @State var textOffset = 0
    @State var animationSpeed = 0.05
    @State var animationCount = 0
    @Binding var version: String?
    let selectedModel: NeuralNetworkModel

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

                Text(selectedModel.title)

                if let version {
                    Text("\nKataGo \(version)")
                        .fixedSize(horizontal: false, vertical: true)
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
                    withAnimation(.linear(duration: 1)
                        .speed(animationSpeed)) {
                            degreesRotating = 360
                        }
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

    private func tapGestureAction() {
        if animationCount < LoadingView.maxAnimationCount {
            degreesRotating = 0
            withAnimation(.bouncy(duration: 1)
                .speed(animationSpeed)) {
                    degreesRotating = 360
                    animationCount = animationCount + 1
                } completion: {
                    animationCount = animationCount - 1
                }
        }
    }
}
