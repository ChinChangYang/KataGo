//
//  AudioModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/29.
//

import AVKit
import SwiftUI

@Observable
public class AudioModel {
    public var playSoundPlayer: AVAudioPlayer?
    public var captureSoundPlayer: AVAudioPlayer?

    public init() {
#if !os(macOS)
        // Through the policy latch, not directly: while a Listening Session
        // owns the session (non-mixable spoken audio), a view rebuild
        // constructing another AudioModel must not clobber it.
        if Thread.isMainThread {
            MainActor.assumeIsolated { AppAudioSessionPolicy.assertSharedPlayback() }
        } else {
            Task { @MainActor in AppAudioSessionPolicy.assertSharedPlayback() }
        }
#endif
    }

    public func playPlaySound(soundEffect: Bool) {
        if soundEffect {
            let randomIndex = Int.random(in: 1...3)
            let playSoundSource = "PlayGoStone\(randomIndex)"

            if let playSoundPath = Bundle.module.path(forResource: playSoundSource, ofType: "mp3") {
                let playSoundUrl = URL(fileURLWithPath: playSoundPath)
                playSoundPlayer = try? AVAudioPlayer(contentsOf: playSoundUrl)
                playSoundPlayer?.play()
            }
        }
    }

    public func playCaptureSound(soundEffect: Bool) {
        if soundEffect {
            let randomIndex = Int.random(in: 1...3)
            let captureSoundSource = "CaptureGoStone\(randomIndex)"

            if let captureSoundUrl = Bundle.module.url(forResource: captureSoundSource, withExtension: "mp3") {
                captureSoundPlayer = try? AVAudioPlayer(contentsOf: captureSoundUrl)
                captureSoundPlayer?.play()
            }
        }
    }
}
