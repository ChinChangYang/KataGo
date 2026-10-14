import Foundation

/// One of KataGo's configuration keys, as the app's engine reads it.
public struct EngineParameter: Sendable, Hashable, Identifiable {
    /// The value's type, and the range the engine enforces when it has one.
    public enum Kind: Sendable, Hashable {
        case bool
        /// `auto`, `true` or `false`.
        case enabled
        case integer(ClosedRange<Int>?)
        case real(ClosedRange<Double>?)
        case text
    }

    /// When a change reaches the engine.
    public enum Timing: Sendable, Hashable {
        /// At once, through `kata-set-param`.
        case live
        /// Only when the engine next launches.
        case launch
    }

    public let key: String
    public let kind: Kind
    public let timing: Timing
    /// The example cfg's section the key sits under; empty when undocumented.
    public let section: String
    /// The example cfg's description; empty when undocumented.
    public let summary: String
    /// The value the example cfg gives, which is KataGo's default when the line
    /// is commented out there.
    public let exampleValue: String?

    public var id: String { key }

    public init(key: String, kind: Kind, timing: Timing, section: String, summary: String, exampleValue: String?) {
        self.key = key
        self.kind = kind
        self.timing = timing
        self.section = section
        self.summary = summary
        self.exampleValue = exampleValue
    }
}

/// The value a parameter has with no custom value, and where it comes from.
public struct ShippedValue: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// The app's own `default_gtp.cfg`.
        case app
        /// KataGo's default, as its example cfg documents it.
        case kataGo
    }

    public let value: String
    public let source: Source
}

/// The app setting that sets a *managed parameter*.
public enum ParameterOwner: String, Sendable, Hashable, CaseIterable {
    case rules
    case boardSize
    case maxBoardSize
    case backend
    case playerProfile
    case thinkingTime
    case analysisSettings
    case app

    /// Names the setting that controls the parameter instead.
    public var settingName: String {
        switch self {
        case .rules: "the game's Rules settings"
        case .boardSize: "the game's board size"
        case .maxBoardSize: "the Max Board Size setting"
        case .backend: "the Backend settings"
        case .playerProfile: "the player's profile"
        case .thinkingTime: "the AI's thinking time"
        case .analysisSettings: "the game's Analysis settings"
        case .app: "the app itself"
        }
    }
}
