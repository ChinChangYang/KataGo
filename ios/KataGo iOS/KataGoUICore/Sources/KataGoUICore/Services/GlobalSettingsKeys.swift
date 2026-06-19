//
//  GlobalSettingsKeys.swift
//  KataGoUICore
//
//  Single source of truth for the GlobalSettings.* UserDefaults keys shared by
//  the iOS @AppStorage sync (GameSplitView) and the macOS observation sync
//  (MacGlobalPreferenceSync).
//
import Foundation

public enum GlobalSettingsKeys {
    public static let soundEffect = "GlobalSettings.soundEffect"
    public static let hapticFeedback = "GlobalSettings.hapticFeedback"
    public static let showVisitsPerSecond = "GlobalSettings.showVisitsPerSecond"
    public static let showCoordinate = "GlobalSettings.showCoordinate"
    public static let showPass = "GlobalSettings.showPass"
    public static let verticalFlip = "GlobalSettings.verticalFlip"
    public static let showOwnership = "GlobalSettings.showOwnership"
    public static let showWinrateBar = "GlobalSettings.showWinrateBar"
    public static let showCharts = "GlobalSettings.showCharts"
    public static let showComments = "GlobalSettings.showComments"
    public static let stoneStyle = "GlobalSettings.stoneStyle"
    public static let moveNumberStyle = "GlobalSettings.moveNumberStyle"
    public static let analysisStyle = "GlobalSettings.analysisStyle"
    public static let analysisInformation = "GlobalSettings.analysisInformation"
}
