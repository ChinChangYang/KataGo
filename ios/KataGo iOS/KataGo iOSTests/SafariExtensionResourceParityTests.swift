//
//  SafariExtensionResourceParityTests.swift
//  KataGo AnytimeTests
//
//  The two Safari appexes ship two COPIES of the page-world hook and the
//  native-messaging relay, and nothing in the build syncs them: they are
//  hand-kept siblings, the way ADR 0007 treated the extension's strings.
//  `content.js` is deliberately different on each platform (macOS sweeps a
//  whole game and polls; iOS analyses one position per message and offers
//  "Scan game"), but `page-hook.js` and `background.js` carry no
//  platform-specific behaviour at all — a site adapter added to one and not
//  the other is a site that silently works on a Mac and does nothing on a
//  phone, with no build error to say so.
//
//  Compare the FILES rather than the bundle: these resources are copied into
//  appexes this test target does not host, so there is no bundle to read them
//  out of. `#filePath` walks to the project directory the way
//  VisionFocusRingTests reaches the committed board assets (:35-38).
//

import Foundation
import Testing

struct SafariExtensionResourceParityTests {
    /// `ios/KataGo iOS/`, the directory both appex folders sit in.
    private var projectDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KataGo iOSTests
            .deletingLastPathComponent()   // KataGo iOS (project dir)
    }

    private func resource(_ appex: String, _ name: String) -> URL {
        projectDirectory
            .appendingPathComponent(appex)
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
    }

    @Test(arguments: ["page-hook.js", "background.js"])
    func sharedResourcesAreByteIdenticalAcrossTheTwoAppexes(name: String) throws {
        let mac = resource("KataGoAnytimeSafariExt", name)
        let ios = resource("KataGoAnytimeSafariExtIOS", name)
        let macData = try Data(contentsOf: mac)
        let iosData = try Data(contentsOf: ios)
        #expect(!macData.isEmpty)
        #expect(macData == iosData,
                "\(name) has drifted between the two appexes — copy one over the other")
    }

    /// The hook's Node hatch is what lets `SafariExtTests` load this file at
    /// all, and it is one line that a refactor can quietly drop. Pin its two
    /// halves: the absent-`window` branch, and the export it performs.
    @Test func theHookKeepsItsNodeTestHatch() throws {
        let source = try String(contentsOf: resource("KataGoAnytimeSafariExt", "page-hook.js"),
                               encoding: .utf8)
        #expect(source.contains(#"typeof window === "undefined""#))
        #expect(source.contains("module.exports"))
    }
}
