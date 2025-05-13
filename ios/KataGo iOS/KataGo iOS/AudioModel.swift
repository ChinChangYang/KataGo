//
//  AudioModel.swift
//  KataGo iOS
//
//  Created by Chin-Chang Yang on 2024/8/29.
//

import AVKit
import SwiftUI

@Observable
class AudioModel {
    var playSoundPlayer: AVAudioPlayer?
    var captureSoundPlayer: AVAudioPlayer?

    init() {
#if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
    }

    func playPlaySound(soundEffect: Bool) {
        if soundEffect {
            let randomIndex = Int.random(in: 1...3)
            let playSoundSource = "PlayGoStone\(randomIndex)"

            if let playSoundPath = Bundle.main.path(forResource: playSoundSource, ofType: "mp3") {
                let playSoundUrl = URL(fileURLWithPath: playSoundPath)
                playSoundPlayer = try? AVAudioPlayer(contentsOf: playSoundUrl)
                playSoundPlayer?.play()
            }
        }
    }

    func playCaptureSound(soundEffect: Bool) {
        if soundEffect {
            let randomIndex = Int.random(in: 1...3)
            let captureSoundSource = "CaptureGoStone\(randomIndex)"

            if let captureSoundPath = Bundle.main.path(forResource: captureSoundSource, ofType: "mp3") {
                let captureSoundUrl = URL(fileURLWithPath: captureSoundPath)
                captureSoundPlayer = try? AVAudioPlayer(contentsOf: captureSoundUrl)
                captureSoundPlayer?.play()
            }
        }
    }
}
