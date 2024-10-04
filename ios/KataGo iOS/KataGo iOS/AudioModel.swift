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
    static let playSoundPath = Bundle.main.path(forResource: "PlayGoStone", ofType: "m4a")
    static let captureSoundPath = Bundle.main.path(forResource: "Capture1GoStone", ofType: "m4a")
    var playSoundPlayer: AVAudioPlayer?
    var captureSoundPlayer: AVAudioPlayer?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func playPlaySound(soundEffect: Bool) {
        if let playSoundPath = AudioModel.playSoundPath, soundEffect {
            let playSoundUrl = URL(fileURLWithPath: playSoundPath)
            playSoundPlayer = try? AVAudioPlayer(contentsOf: playSoundUrl)
            playSoundPlayer?.play()
        }
    }

    func playCaptureSound(soundEffect: Bool) {
        if let captureSoundPath = AudioModel.captureSoundPath, soundEffect {
            let captureSoundUrl = URL(fileURLWithPath: captureSoundPath)
            captureSoundPlayer = try? AVAudioPlayer(contentsOf: captureSoundUrl)
            captureSoundPlayer?.play()
        }
    }
}
