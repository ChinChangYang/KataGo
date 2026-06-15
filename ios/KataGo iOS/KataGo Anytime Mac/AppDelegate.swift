import AppKit
import SwiftData
import KataGoUICore

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    let modelContainer = try! ModelContainer(for: GameRecord.self)

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCoreMLBridge()  // from the copied CoreMLComputeHandleLoader.swift
        registerDownloadedHasher(BinFileHasher.shared.identityForDownloadedFile)
        let wc = MainWindowController(modelContainer: modelContainer)
        wc.showWindow(nil)
        windowController = wc
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}
