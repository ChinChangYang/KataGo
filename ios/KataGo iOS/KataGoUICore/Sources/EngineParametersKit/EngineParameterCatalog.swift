import Foundation

/// Every engine parameter the editor offers, and which ones the app keeps for
/// itself.
public enum EngineParameterCatalog {
    /// Keys that do nothing useful in this app: logging, test and debug
    /// switches, and the device keys of backends the app does not build.
    static let hiddenKeys: Set<String> = [
        "logAllGTPCommunication", "logSearchInfo", "logSearchInfoForChosenMove",
        "startupPrintMessageToStderr", "ogsChatToStderr", "forDeterministicTesting",
        "debugSkipNeuralNet", "numBots", "autoAvoidRepeatDir", "autoAvoidRepeatSaveChunkSize",
        "cudaDisableWarmup", "inputsUseNHWC", "numEigenThreadsPerModel",
        "deviceToUse", "deviceToUseModel", "deviceToUseThread",
        "gpuToUse", "gpuToUseModel", "gpuToUseThread",
    ]

    /// Keys the app sets itself, per turn, per game or per launch. A custom
    /// value for one would be overwritten, or would break what the app reads.
    static let managedKeys: [String: ParameterOwner] = {
        var keys: [String: ParameterOwner] = [:]
        func assign(_ owner: ParameterOwner, _ names: [String]) {
            for name in names { keys[name] = owner }
        }
        assign(.rules, ["rules", "koRule", "scoringRule", "taxRule", "multiStoneSuicideLegal",
                        "hasButton", "whiteHandicapBonus", "friendlyPassOk", "whiteBonusPerHandicapStone",
                        "komi", "ignoreGTPAndForceKomi"])
        assign(.boardSize, ["defaultBoardSize", "defaultBoardXSize", "defaultBoardYSize"])
        assign(.maxBoardSize, ["maxBoardSizeForNNBuffer", "maxBoardXSizeForNNBuffer", "maxBoardYSizeForNNBuffer",
                               "requireMaxBoardSize", "gtpForceMaxNNSize"])
        assign(.backend, ["numSearchThreads", "nnMaxBatchSize", "numNNServerThreadsPerModel",
                          "mlxTunerFull", "mlxReTune", "mlxUseFP16", "useFP16"])
        assign(.playerProfile, ["humanSLProfile", "humanSLChosenMoveProp",
                                "humanSLRootExploreProbWeightless", "humanSLRootExploreProbWeightful",
                                "chosenMoveTemperatureEarly", "chosenMoveTemperature",
                                "chosenMoveTemperatureHalflife", "chosenMoveTemperatureOnlyBelowProb",
                                "humanSLChosenMovePiklLambda", "winLossUtilityFactor",
                                "staticScoreUtilityFactor", "dynamicScoreUtilityFactor",
                                "useLcbForSelection", "useUncertainty", "useNoisePruning",
                                "subtreeValueBiasFactor"])
        assign(.thinkingTime, ["maxTime", "maxVisits"])
        assign(.analysisSettings, ["playoutDoublingAdvantage", "analysisWideRootNoise"])
        assign(.app, ["reportAnalysisWinratesAs", "homeDataDir", "ponderingEnabled", "logToStderr"])
        return keys
    }()

    /// The catalog, in key order: every parameter the engine reads, less the
    /// hidden ones. Managed parameters are included, to be shown read-only.
    public static let parameters: [EngineParameter] = generatedParameters
        .filter { !hiddenKeys.contains($0.key) }
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }

    private static let byKey: [String: EngineParameter] =
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.key, $0) })

    /// The catalog entry for `key`, or nil for a key the catalog does not list.
    public static func parameter(forKey key: String) -> EngineParameter? {
        byKey[key]
    }

    /// The setting that controls `key`, or nil when the key may take a custom value.
    public static func owner(ofKey key: String) -> ParameterOwner? {
        managedKeys[key]
    }

    /// The value `key` has with no custom value, or nil when neither the app's
    /// cfg nor KataGo's example cfg says.
    public static func shippedValue(forKey key: String) -> ShippedValue? {
        if let value = generatedAppValues[key] {
            return ShippedValue(value: value, source: .app)
        }
        if let value = byKey[key]?.exampleValue, !value.isEmpty {
            return ShippedValue(value: value, source: .kataGo)
        }
        return nil
    }

    /// When a change to `key` reaches the engine. A key the catalog does not
    /// list is delivered at launch only.
    public static func timing(ofKey key: String) -> EngineParameter.Timing {
        byKey[key]?.timing ?? .launch
    }

    /// Search `parameters` by key, section or description.
    public static func search(_ query: String) -> [EngineParameter] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return parameters }
        return parameters.filter {
            $0.key.localizedCaseInsensitiveContains(trimmed)
                || $0.section.localizedCaseInsensitiveContains(trimmed)
                || $0.summary.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
