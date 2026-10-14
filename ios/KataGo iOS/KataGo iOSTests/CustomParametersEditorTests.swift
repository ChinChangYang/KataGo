//
//  CustomParametersEditorTests.swift
//  KataGo AnytimeTests
//
//  The Engine Parameters screen's editor: every change is saved at once, and
//  only live parameters are told to a running engine.
//

import Foundation
import Testing
@testable import KataGoUICore

@MainActor
struct CustomParametersEditorTests {
    private func makeEditor() -> (CustomParametersEditor, CustomParameterStore, Box) {
        let name = "CustomParametersEditorTests.\(UUID().uuidString)"
        let store = CustomParameterStore(defaults: UserDefaults(suiteName: name)!)
        let editor = CustomParametersEditor(store: store)
        let sent = Box()
        editor.sendLiveCommand = { sent.commands.append($0) }
        return (editor, store, sent)
    }

    final class Box { var commands: [String] = [] }

    @Test func aLiveValueIsSavedAndSent() {
        let (editor, store, sent) = makeEditor()
        #expect(editor.set("cpuctExploration", to: "1.2") == nil)
        #expect(store.load().values == ["cpuctExploration": "1.2"])
        #expect(sent.commands == ["kata-set-param cpuctExploration 1.2"])
    }

    @Test func aLaunchValueIsSavedButNotSent() {
        let (editor, store, sent) = makeEditor()
        editor.set("nnCacheSizePowerOfTwo", to: "18")
        #expect(store.load().values == ["nnCacheSizePowerOfTwo": "18"])
        #expect(sent.commands.isEmpty)
    }

    @Test func aRefusedValueIsNeitherSavedNorSent() {
        let (editor, store, sent) = makeEditor()
        #expect(editor.set("numSearchThreads", to: "8") == .managed(.backend))
        #expect(store.load().isEmpty)
        #expect(sent.commands.isEmpty)
    }

    @Test func aResetSendsTheShippedValueBack() {
        let (editor, store, sent) = makeEditor()
        editor.set("cpuctExploration", to: "1.2")
        editor.reset("cpuctExploration")
        #expect(store.load().isEmpty)
        #expect(sent.commands.last == "kata-set-param cpuctExploration 1.0")
    }

    @Test func importedLiveValuesAreSent() {
        let (editor, _, sent) = makeEditor()
        _ = editor.importCfgText("cpuctExploration = 1.1\nnnCacheSizePowerOfTwo = 18")
        #expect(sent.commands == ["kata-set-param cpuctExploration 1.1"])
    }

    @Test func resetAllSendsEveryLiveKeyBack() {
        let (editor, store, sent) = makeEditor()
        editor.set("cpuctExploration", to: "1.2")
        editor.set("nnCacheSizePowerOfTwo", to: "18")
        sent.commands = []
        editor.resetAll()
        #expect(store.load().isEmpty)
        #expect(sent.commands == ["kata-set-param cpuctExploration 1.0"])
    }
}
