import Foundation

/// Why a custom value was not accepted.
public enum CustomValueError: Error, Sendable, Hashable {
    /// Not a KataGo key: letters, digits and underscores, starting with a letter.
    case malformedKey
    /// The app sets this parameter itself.
    case managed(ParameterOwner)
    case emptyValue
    /// `-override-config` splits on commas and `=`, `kata-set-param` on spaces, and a
    /// cfg line ends at a newline or `#`.
    case forbiddenCharacter
    case notABool
    case notAnEnabled
    case notAnInteger
    case notANumber
    case outOfRange(String)

    public var message: String {
        switch self {
        case .malformedKey: "A key is letters, digits and underscores, starting with a letter."
        case .managed(let owner): "The app sets this itself, through \(owner.settingName)."
        case .emptyValue: "Enter a value."
        case .forbiddenCharacter: "A value cannot contain a space, a comma, =, # or a line break."
        case .notABool: "Enter true or false."
        case .notAnEnabled: "Enter auto, true or false."
        case .notAnInteger: "Enter a whole number."
        case .notANumber: "Enter a number."
        case .outOfRange(let range): "Enter a value from \(range)."
        }
    }
}

/// The person's own values for engine parameters: app-wide, kept on the device.
public struct CustomParameters: Sendable, Hashable {
    /// Key to value, each already validated.
    public private(set) var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }
    public var count: Int { values.count }

    /// Keys in a stable order, so launch arguments and exports are deterministic.
    public var sortedKeys: [String] {
        values.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Checks `value` for `key` and returns it in the form the engine reads.
    public static func validate(key: String, value: String) -> Result<String, CustomValueError> {
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return .failure(.malformedKey)
        }
        if let owner = EngineParameterCatalog.owner(ofKey: key) {
            return .failure(.managed(owner))
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.emptyValue) }
        guard trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ",=# \t\n\r")) == nil else {
            return .failure(.forbiddenCharacter)
        }
        guard let kind = EngineParameterCatalog.parameter(forKey: key)?.kind else {
            return .success(trimmed)
        }
        switch kind {
        case .bool:
            let lowered = trimmed.lowercased()
            return ["true", "false"].contains(lowered) ? .success(lowered) : .failure(.notABool)
        case .enabled:
            let lowered = trimmed.lowercased()
            return ["auto", "true", "false"].contains(lowered) ? .success(lowered) : .failure(.notAnEnabled)
        case .integer(let range):
            guard let number = Int(trimmed) else { return .failure(.notAnInteger) }
            if let range, !range.contains(number) {
                return .failure(.outOfRange("\(range.lowerBound) to \(range.upperBound)"))
            }
            return .success(String(number))
        case .real(let range):
            guard let number = Double(trimmed), number.isFinite else { return .failure(.notANumber) }
            if let range, !range.contains(number) {
                return .failure(.outOfRange("\(format(range.lowerBound)) to \(format(range.upperBound))"))
            }
            return .success(trimmed)
        case .text:
            return .success(trimmed)
        }
    }

    private static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    /// Sets `key` to `value` when it validates; leaves the set unchanged otherwise.
    @discardableResult
    public mutating func set(_ key: String, to value: String) -> Result<String, CustomValueError> {
        let result = Self.validate(key: key, value: value)
        if case .success(let accepted) = result {
            values[key] = accepted
        }
        return result
    }

    public mutating func reset(_ key: String) {
        values[key] = nil
    }

    public mutating func resetAll() {
        values = [:]
    }

    /// `key=value` entries, one per `-override-config` argument. Every custom
    /// value goes in, live ones too, so they survive a relaunch.
    public var launchOverrides: [String] {
        sortedKeys.map { "\($0)=\(values[$0]!)" }
    }

    /// The `kata-set-param` commands that re-apply the live custom values to a
    /// running engine.
    public var liveCommands: [String] {
        sortedKeys
            .filter { EngineParameterCatalog.timing(ofKey: $0) == .live }
            .map { "kata-set-param \($0) \(values[$0]!)" }
    }

    /// The changes since `launched` that a running engine cannot take live and
    /// so wait for a relaunch: every changed launch-timing value, and a live
    /// value reset to a shipped value nobody knows (there is nothing to send).
    public func pendingLaunchKeys(launchedWith launched: CustomParameters) -> [String] {
        let keys = Set(values.keys).union(launched.values.keys)
        return keys
            .filter { key in
                guard values[key] != launched.values[key] else { return false }
                if EngineParameterCatalog.timing(ofKey: key) == .launch { return true }
                return values[key] == nil && EngineParameterCatalog.shippedValue(forKey: key) == nil
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The `kata-set-param` that brings a running engine in line with this
    /// set's value for `key`: the custom value, or the shipped one after a
    /// reset. Nil for a launch-timing key, or a reset with no known value.
    public func liveCommand(forKey key: String) -> String? {
        guard EngineParameterCatalog.timing(ofKey: key) == .live,
              let value = values[key] ?? EngineParameterCatalog.shippedValue(forKey: key)?.value
        else { return nil }
        return "kata-set-param \(key) \(value)"
    }
}

// MARK: - cfg text

/// One line of pasted cfg text that did not become a custom value.
public struct SkippedCfgLine: Sendable, Hashable {
    public let key: String
    public let reason: CustomValueError
}

extension CustomParameters {
    /// The custom values as cfg lines, ready to paste into a `gtp.cfg`.
    public var cfgText: String {
        sortedKeys.map { "\($0) = \(values[$0]!)" }.joined(separator: "\n")
    }

    /// Adds every `key = value` line of `text` that validates, replacing any
    /// existing value for that key. Comments and blank lines are ignored.
    public mutating func importCfgText(_ text: String) -> (imported: [String], skipped: [SkippedCfgLine]) {
        var imported: [String] = []
        var skipped: [SkippedCfgLine] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            guard let equals = line.firstIndex(of: "=") else {
                skipped.append(SkippedCfgLine(key: line, reason: .malformedKey))
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch set(key, to: value) {
            case .success: imported.append(key)
            case .failure(let reason): skipped.append(SkippedCfgLine(key: key, reason: reason))
            }
        }
        return (imported, skipped)
    }
}

// MARK: - Storage

/// Keeps the custom parameters in UserDefaults, on this device only.
public struct CustomParameterStore: @unchecked Sendable {
    public static let defaultsKey = "EngineParameters.customValues"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored values. Anything that no longer validates (a key the app has
    /// since started to manage, a value out of a new range) is dropped.
    public func load() -> CustomParameters {
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        var parameters = CustomParameters()
        for (key, value) in stored {
            parameters.set(key, to: value)
        }
        return parameters
    }

    public func save(_ parameters: CustomParameters) {
        if parameters.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(parameters.values, forKey: Self.defaultsKey)
        }
    }
}
