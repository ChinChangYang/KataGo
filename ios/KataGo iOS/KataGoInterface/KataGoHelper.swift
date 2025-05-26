//
//  KataGoHelper.swift
//  KataGoHelper
//
//  Created by Chin-Chang Yang on 2024/7/6.
//

import Foundation

public class KataGoHelper {

    public class func runGtp(modelPath: String? = nil, useMetal: Bool = false) {
        let mainBundle = Bundle.main
        let modelName = "default_model"
        let modelExt = "bin.gz"
        
        let mainModelPath = modelPath ?? mainBundle.path(forResource: modelName,
                                                         ofType: modelExt)
        
        let humanModelName = "b18c384nbt-humanv0"
        let humanModelExt = "bin.gz"
        
        let humanModelPath = mainBundle.path(forResource: humanModelName,
                                             ofType: humanModelExt)

        let configName = "default_gtp"
        let configExt = "cfg"

        let configPath = mainBundle.path(forResource: configName,
                                         ofType: configExt)

        let coremlDeviceToUse = useMetal ? 0 : 100

        KataGoRunGtp(std.string(mainModelPath),
                     std.string(humanModelPath),
                     std.string(configPath),
                     Int32(coremlDeviceToUse))
    }

    public class func getMessageLine() -> String {
        let cppLine = KataGoGetMessageLine()

        return String(cppLine)
    }

    public class func sendCommand(_ command: String) {
        KataGoSendCommand(std.string(command))
    }

    public class func sendMessage(_ message: String) {
        KataGoSendMessage(std.string(message))
    }
}
