//
//  EngineParametersKitTests.swift
//  EngineParametersKitTests
//
//  Engine-free tests for the engine-parameter catalog and custom values.
//  Runs via `swift test --filter EngineParametersKitTests`.
//

import Foundation
import Testing
@testable import EngineParametersKit

@Suite struct EngineParameterCatalogTests {
    @Test func searchParametersAreLiveWithTheEnginesRange() throws {
        let cpuct = try #require(EngineParameterCatalog.parameter(forKey: "cpuctExploration"))
        #expect(cpuct.kind == .real(0.0...10.0))
        #expect(cpuct.timing == .live)
        #expect(cpuct.summary.isEmpty == false)
    }

    @Test func parametersReadOutsideTheSearchAreLaunchOnly() {
        #expect(EngineParameterCatalog.timing(ofKey: "nnCacheSizePowerOfTwo") == .launch)
        #expect(EngineParameterCatalog.timing(ofKey: "resignThreshold") == .launch)
    }

    @Test func searchParametersKataSetParamRefusesAreLaunchOnly() {
        for key in ["useEvalCache", "evalCacheMinVisits", "nodeTableShardsPowerOfTwo",
                    "avoidRepeatedPatternUtility", "dynamicPlayoutDoublingAdvantageCapPerOppLead"] {
            #expect(EngineParameterCatalog.timing(ofKey: key) == .launch, "\(key)")
        }
    }

    @Test func parametersKataSetParamHandlesItselfAreLive() {
        for key in ["allowResignation", "delayMoveScale", "delayMoveMax", "analysisIgnorePreRootHistory"] {
            #expect(EngineParameterCatalog.timing(ofKey: key) == .live, "\(key)")
        }
    }

    @Test func unlistedKeysAreDeliveredAtLaunch() {
        #expect(EngineParameterCatalog.parameter(forKey: "someFutureKey") == nil)
        #expect(EngineParameterCatalog.timing(ofKey: "someFutureKey") == .launch)
    }

    @Test func hiddenKeysAreNotListed() {
        for key in EngineParameterCatalog.hiddenKeys {
            #expect(EngineParameterCatalog.parameter(forKey: key) == nil, "\(key)")
        }
    }

    @Test func managedParametersAreListedWithTheirOwner() {
        #expect(EngineParameterCatalog.parameter(forKey: "numSearchThreads") != nil)
        #expect(EngineParameterCatalog.owner(ofKey: "numSearchThreads") == .backend)
        #expect(EngineParameterCatalog.owner(ofKey: "reportAnalysisWinratesAs") == .app)
        #expect(EngineParameterCatalog.owner(ofKey: "winLossUtilityFactor") == .playerProfile)
        #expect(EngineParameterCatalog.owner(ofKey: "cpuctExploration") == nil)
    }

    @Test func shippedValueComesFromTheAppsCfgFirst() {
        #expect(EngineParameterCatalog.shippedValue(forKey: "numSearchThreads") == ShippedValue(value: "2", source: .app))
        #expect(EngineParameterCatalog.shippedValue(forKey: "cpuctExploration") == ShippedValue(value: "1.0", source: .kataGo))
    }

    @Test func searchMatchesKeySectionAndDescription() {
        #expect(EngineParameterCatalog.search("cpuct").contains { $0.key == "cpuctExploration" })
        #expect(EngineParameterCatalog.search("Resignation").contains { $0.key == "resignConsecTurns" })
        #expect(EngineParameterCatalog.search("").count == EngineParameterCatalog.parameters.count)
    }

    /// The generated app values must match the bundled cfg; a mismatch means
    /// the generator was not re-run after default_gtp.cfg changed.
    @Test func generatedAppValuesMatchTheBundledCfg() throws {
        let cfg = URL(filePath: #filePath)
            .deletingLastPathComponent()  // EngineParametersKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // KataGoUICore
            .deletingLastPathComponent()  // KataGo iOS
            .appending(path: "Resources/default_gtp.cfg")
        var parsed: [String: String] = [:]
        for line in try String(contentsOf: cfg, encoding: .utf8).split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = content.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            parsed[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        #expect(parsed == EngineParameterCatalog.generatedAppValues)
    }
}

@Suite struct CustomValueValidationTests {
    @Test func managedParametersAreRefused() {
        #expect(CustomParameters.validate(key: "numSearchThreads", value: "4") == .failure(.managed(.backend)))
    }

    @Test func numbersOutsideTheEnginesRangeAreRefused() {
        #expect(CustomParameters.validate(key: "cpuctExploration", value: "11") == .failure(.outOfRange("0 to 10")))
        #expect(CustomParameters.validate(key: "nnCacheSizePowerOfTwo", value: "49") == .failure(.outOfRange("-1 to 48")))
        #expect(CustomParameters.validate(key: "cpuctExploration", value: "1.5") == .success("1.5"))
    }

    @Test func valuesMustParseAsTheirKind() {
        #expect(CustomParameters.validate(key: "nnCacheSizePowerOfTwo", value: "1.5") == .failure(.notAnInteger))
        #expect(CustomParameters.validate(key: "cpuctExploration", value: "abc") == .failure(.notANumber))
        #expect(CustomParameters.validate(key: "cpuctExploration", value: "inf") == .failure(.notANumber))
        #expect(CustomParameters.validate(key: "rootNoiseEnabled", value: "yes") == .failure(.notABool))
        #expect(CustomParameters.validate(key: "rootNoiseEnabled", value: " TRUE ") == .success("true"))
        #expect(CustomParameters.validate(key: "cleanupBeforePass", value: "Auto") == .success("auto"))
    }

    @Test func valuesThatWouldSplitAnArgumentAreRefused() {
        for value in ["1,2", "a=b", "1 2", "1#2"] {
            #expect(CustomParameters.validate(key: "searchRandSeed", value: value) == .failure(.forbiddenCharacter), "\(value)")
        }
        #expect(CustomParameters.validate(key: "searchRandSeed", value: "  ") == .failure(.emptyValue))
    }

    @Test func unlistedKeysAcceptAnyWellFormedValue() {
        #expect(CustomParameters.validate(key: "someFutureKey", value: "anything") == .success("anything"))
        #expect(CustomParameters.validate(key: "1bad", value: "1") == .failure(.malformedKey))
        #expect(CustomParameters.validate(key: "bad key", value: "1") == .failure(.malformedKey))
    }
}

@Suite struct CustomParametersTests {
    private func sample() -> CustomParameters {
        var parameters = CustomParameters()
        parameters.set("nnCacheSizePowerOfTwo", to: "18")
        parameters.set("cpuctExploration", to: "1.2")
        parameters.set("someFutureKey", to: "x")
        return parameters
    }

    @Test func aRefusedValueLeavesTheSetUnchanged() {
        var parameters = sample()
        parameters.set("cpuctExploration", to: "99")
        #expect(parameters.values["cpuctExploration"] == "1.2")
    }

    @Test func everyValueGoesInAtLaunchInKeyOrder() {
        #expect(sample().launchOverrides == ["cpuctExploration=1.2", "nnCacheSizePowerOfTwo=18", "someFutureKey=x"])
    }

    @Test func onlyLiveValuesAreSentToARunningEngine() {
        #expect(sample().liveCommands == ["kata-set-param cpuctExploration 1.2"])
    }

    @Test func pendingLaunchKeysIgnoreLiveChanges() {
        let launched = sample()
        var current = launched
        current.set("cpuctExploration", to: "2")
        #expect(current.pendingLaunchKeys(launchedWith: launched).isEmpty)
        current.set("nnCacheSizePowerOfTwo", to: "20")
        current.reset("someFutureKey")
        #expect(current.pendingLaunchKeys(launchedWith: launched) == ["nnCacheSizePowerOfTwo", "someFutureKey"])
    }

    @Test func resetAllEmptiesTheSet() {
        var parameters = sample()
        parameters.resetAll()
        #expect(parameters.isEmpty)
    }
}

@Suite struct CfgTextTests {
    @Test func pastedCfgImportsValidLinesAndReportsTheRest() {
        var parameters = CustomParameters()
        let result = parameters.importCfgText("""
            # Search
            cpuctExploration = 1.1   # a bit wider
            numSearchThreads = 8

            nnCacheSizePowerOfTwo=99
            just words
            """)
        #expect(result.imported == ["cpuctExploration"])
        #expect(result.skipped == [
            SkippedCfgLine(key: "numSearchThreads", reason: .managed(.backend)),
            SkippedCfgLine(key: "nnCacheSizePowerOfTwo", reason: .outOfRange("-1 to 48")),
            SkippedCfgLine(key: "just words", reason: .malformedKey),
        ])
        #expect(parameters.values == ["cpuctExploration": "1.1"])
    }

    @Test func exportedCfgImportsBackUnchanged() {
        var original = CustomParameters()
        original.set("cpuctExploration", to: "1.2")
        original.set("rootNoiseEnabled", to: "true")
        var copy = CustomParameters()
        _ = copy.importCfgText(original.cfgText)
        #expect(copy == original)
        #expect(original.cfgText == "cpuctExploration = 1.2\nrootNoiseEnabled = true")
    }
}

@Suite struct CustomParameterStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "EngineParametersKitTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func savedValuesLoadBack() {
        let store = CustomParameterStore(defaults: freshDefaults())
        var parameters = CustomParameters()
        parameters.set("cpuctExploration", to: "1.2")
        store.save(parameters)
        #expect(store.load() == parameters)
    }

    @Test func storedValuesThatNoLongerValidateAreDropped() {
        let defaults = freshDefaults()
        defaults.set(["numSearchThreads": "8", "cpuctExploration": "50", "rootNoiseEnabled": "true"],
                     forKey: CustomParameterStore.defaultsKey)
        #expect(CustomParameterStore(defaults: defaults).load().values == ["rootNoiseEnabled": "true"])
    }

    @Test func savingAnEmptySetRemovesTheEntry() {
        let defaults = freshDefaults()
        let store = CustomParameterStore(defaults: defaults)
        var parameters = CustomParameters()
        parameters.set("cpuctExploration", to: "1.2")
        store.save(parameters)
        store.save(CustomParameters())
        #expect(defaults.object(forKey: CustomParameterStore.defaultsKey) == nil)
    }
}
