//
//  KataGoHelper.swift
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

import Foundation

public class KataGoHelper {

    private class var configName: String {
        ProcessInfo.processInfo.isiOSAppOnMac ? "macos_gtp" : "default_gtp"
    }

    public class func runGtp() {
        let mainBundle = Bundle.main
        let modelName = "default_model"
        let modelExt = "bin.gz"

        let modelPath = mainBundle.path(forResource: modelName,
                                        ofType: modelExt)

        let humanModelName = "b18c384nbt-humanv0"
        let humanModelExt = "bin.gz"

        let humanModelPath = mainBundle.path(forResource: humanModelName,
                                             ofType: humanModelExt)

        let configExt = "cfg"

        let configPath = mainBundle.path(forResource: configName,
                                         ofType: configExt)

        KataGoRunGtp(std.string(modelPath),
                     std.string(humanModelPath),
                     std.string(configPath))
    }

    public class func getMessageLine() -> String {
        let cppLine = KataGoGetMessageLine()

        return String(cppLine)
    }

    public class func sendCommand(_ command: String) {
        KataGoSendCommand(std.string(command))
    }

    public class func loadSgf(_ sgf: String) {
        let supportDirectory =
        try? FileManager.default.url(for: .documentDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: true)

        if let supportDirectory {
            let file = supportDirectory.appendingPathComponent("temp.sgf")
            do {
                try sgf.write(to: file, atomically: false, encoding: .utf8)
                let path = file.path()
                KataGoHelper.sendCommand("loadsgf \(path)")
            } catch {
                // Do nothing
            }
        }
    }
}
