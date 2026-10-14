//
//  CustomParametersEditor.swift
//  KataGoUICore
//
//  The editor behind the Engine Parameters screen: owns the person's custom
//  values while the screen is open, saves every change at once, and tells a
//  running engine about the live ones. Launch-timing changes only wait; the
//  screen offers the relaunch.
//

import Foundation
import Observation

@MainActor @Observable
public final class CustomParametersEditor {
    public private(set) var parameters: CustomParameters

    @ObservationIgnored private let store: CustomParameterStore

    /// Sends one GTP command to the running engine. The host wires it to the
    /// session's command gate, which drops it while no engine is answering;
    /// the next launch carries the value instead.
    @ObservationIgnored public var sendLiveCommand: ((String) -> Void)?

    public init(store: CustomParameterStore = CustomParameterStore()) {
        self.store = store
        self.parameters = store.load()
    }

    /// Sets `key` to `value`. Returns why it was refused, or nil when it was
    /// saved (and, for a live key, sent).
    @discardableResult
    public func set(_ key: String, to value: String) -> CustomValueError? {
        switch parameters.set(key, to: value) {
        case .success:
            commit(changedKeys: [key])
            return nil
        case .failure(let error):
            return error
        }
    }

    public func reset(_ key: String) {
        guard parameters.values[key] != nil else { return }
        parameters.reset(key)
        commit(changedKeys: [key])
    }

    public func resetAll() {
        let keys = parameters.sortedKeys
        parameters.resetAll()
        commit(changedKeys: keys)
    }

    /// Adds the valid `key = value` lines of pasted cfg text.
    public func importCfgText(_ text: String) -> (imported: [String], skipped: [SkippedCfgLine]) {
        let result = parameters.importCfgText(text)
        commit(changedKeys: result.imported)
        return result
    }

    private func commit(changedKeys: [String]) {
        store.save(parameters)
        for key in changedKeys {
            if let command = parameters.liveCommand(forKey: key) {
                sendLiveCommand?(command)
            }
        }
    }
}
