//
//  CustomModelStoreTests.swift
//  KataGo AnytimeTests
//
//  Pins the persistence and naming rules for user-imported networks.
//
//  The load-bearing property under test is TITLE UNIQUENESS. The persisted
//  selection — the shared ModelRunnerView.selectedModelTitle key that iOS,
//  macOS and visionOS all resolve through — stores a model's title, so two
//  models sharing one title makes the launched network ambiguous. Also pinned:
//  the projection's id stability, without which a rebuilt list would compare
//  unequal to itself (NeuralNetworkModel's synthesized == includes id).
//

import Foundation
import Testing
@testable import KataGoUICore

struct CustomModelStoreTests {

    /// A throwaway defaults suite so tests never touch the app's real
    /// UserDefaults (which also carry the simulator host's state).
    private func makeStore(_ name: String = #function) -> (CustomModelStore, UserDefaults) {
        let suiteName = "CustomModelStoreTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (CustomModelStore(defaults: defaults), defaults)
    }

    private func makeRecord(_ name: String, id: UUID = UUID(), size: Int = 1_000) -> CustomModelRecord {
        CustomModelRecord(id: id,
                          displayName: name,
                          fileName: CustomModelStore.makeFileName(id: id, sourceExtension: "bin.gz"),
                          fileSize: size)
    }

    // MARK: - Records

    @Test func emptyDefaultsHoldNoRecords() {
        let (store, _) = makeStore()
        #expect(store.records.isEmpty)
        #expect(store.models.isEmpty)
    }

    @Test func recordsRoundTripThroughDefaults() {
        let (store, _) = makeStore()
        let record = makeRecord("My Net", size: 4_842_138)
        store.add(record)

        let reread = store.records
        #expect(reread.count == 1)
        #expect(reread.first?.id == record.id)
        #expect(reread.first?.displayName == "My Net")
        #expect(reread.first?.fileName == record.fileName)
        #expect(reread.first?.fileSize == 4_842_138)
    }

    @Test func renameAndNotesPersist() {
        let (store, _) = makeStore()
        let record = makeRecord("Before")
        store.add(record)

        store.rename(id: record.id, to: "After")
        store.setNotes(id: record.id, to: "Finetuned for 9x9.")

        #expect(store.record(id: record.id)?.displayName == "After")
        #expect(store.record(id: record.id)?.notes == "Finetuned for 9x9.")
    }

    @Test func removeRecordDropsOnlyThatRecord() {
        let (store, _) = makeStore()
        let keep = makeRecord("Keep")
        let drop = makeRecord("Drop")
        store.add(keep)
        store.add(drop)

        store.removeRecord(id: drop.id)

        #expect(store.records.map(\.id) == [keep.id])
    }

    // MARK: - Naming

    @Test func anUncontestedNameIsLeftAlone() {
        let (store, _) = makeStore()
        #expect(store.uniqueDisplayName("Totally Novel Net") == "Totally Novel Net")
    }

    @Test func aNameCollidingWithTheBuiltInCatalogIsSuffixed() {
        let (store, _) = makeStore()
        // Collisions with catalog titles matter as much as collisions between
        // custom nets: title is the persisted selection key for BOTH.
        let catalogTitle = NeuralNetworkModel.allCases[0].title
        #expect(store.uniqueDisplayName(catalogTitle) == "\(catalogTitle) (2)")
    }

    @Test func collidingNamesChainUpwards() {
        let (store, _) = makeStore()
        store.add(makeRecord("Net"))
        #expect(store.uniqueDisplayName("Net") == "Net (2)")

        store.add(makeRecord("Net (2)"))
        #expect(store.uniqueDisplayName("Net") == "Net (3)")
    }

    @Test func renamingARecordDoesNotCollideWithItself() {
        let (store, _) = makeStore()
        let record = makeRecord("Stable")
        store.add(record)
        // Re-committing the same name must not walk it to "Stable (2)" —
        // the detail screen commits on every blur, not only on a real edit.
        #expect(store.rename(id: record.id, to: "Stable") == "Stable")
        #expect(store.record(id: record.id)?.displayName == "Stable")
    }

    @Test func renamingOntoAnotherRecordsNameIsSuffixed() {
        let (store, _) = makeStore()
        store.add(makeRecord("Taken"))
        let other = makeRecord("Other")
        store.add(other)

        #expect(store.rename(id: other.id, to: "Taken") == "Taken (2)")
    }

    @Test func blankNamesFallBackRatherThanProducingAnUnnamedRow() {
        let (store, _) = makeStore()
        #expect(store.uniqueDisplayName("") == "Custom Network")
        #expect(store.uniqueDisplayName("   ") == "Custom Network")
        #expect(store.uniqueDisplayName("  Padded  ") == "Padded")
    }

    // MARK: - File naming

    @Test func twoPartExtensionsWinOverTheBareGz() {
        // The engine picks its float format from .bin.gz vs .txt.gz, so
        // collapsing either to "gz" would hand it the wrong reader.
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/net.bin.gz")) == "bin.gz")
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/net.txt.gz")) == "txt.gz")
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/net.bin")) == "bin")
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/net.txt")) == "txt")
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/net.gz")) == "gz")
    }

    @Test func extensionMatchingIgnoresCase() {
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/NET.BIN.GZ")) == "bin.gz")
    }

    @Test func unrecognizedExtensionsAreRejected() {
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/photo.jpg")) == nil)
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/game.sgf")) == nil)
        #expect(CustomModelStore.modelFileExtension(of: URL(filePath: "/a/noextension")) == nil)
    }

    @Test func generatedFileNamesAreUniquePerImport() {
        let first = CustomModelStore.makeFileName(id: UUID(), sourceExtension: "bin.gz")
        let second = CustomModelStore.makeFileName(id: UUID(), sourceExtension: "bin.gz")
        #expect(first != second)
        #expect(first.hasPrefix("custom-"))
        #expect(first.hasSuffix(".bin.gz"))
    }

    // MARK: - Projection

    @Test func projectedModelsKeepAStableIdentityAcrossRebuilds() {
        let (store, _) = makeStore()
        store.add(makeRecord("Stable Identity"))

        // Two independent reads must compare equal. NeuralNetworkModel's
        // synthesized == includes id, so minting a fresh UUID per rebuild
        // would silently break every equality check and onChange downstream.
        #expect(store.models == store.models)
    }

    @Test func projectedModelsCarryCustomLocationAndFlags() {
        let (store, _) = makeStore()
        let record = makeRecord("Projected")
        store.add(record)

        let model = store.models.first
        #expect(model?.isCustom == true)
        #expect(model?.builtIn == false)
        #expect(model?.url == "")
        #expect(model?.subdirectory == CustomModelStore.subdirectoryName)
        #expect(model?.id == record.id)
        // 37 = the engine's compiled maximum. A file cannot declare the largest
        // board it was trained for, so the real cap is the per-model Max Board
        // Size setting, which defaults to 19.
        #expect(model?.nnLen == 37)
        #expect(model?.downloadedURL?.path().contains(CustomModelStore.subdirectoryName) == true)
        #expect(model?.downloadedURL?.lastPathComponent == record.fileName)
    }

    @Test func anEmptyNotesFieldStillDescribesTheNetwork() {
        let (store, _) = makeStore()
        store.add(makeRecord("No Notes"))
        // The detail screen renders `description`; leaving it blank would show
        // an empty block where catalog entries show rich text.
        #expect(store.models.first?.description.isEmpty == false)
    }

    @Test func notesBecomeTheProjectedDescription() {
        let (store, _) = makeStore()
        let record = makeRecord("Annotated")
        store.add(record)
        store.setNotes(id: record.id, to: "Trained on 9x9 only.")
        #expect(store.models.first?.description == "Trained on 9x9 only.")
    }

    // MARK: - Catalog merge

    @Test func allAvailableIsTheCatalogWhenNothingIsImported() {
        // `allAvailable` reads the standard defaults suite, which on a clean
        // test host has no custom records.
        #expect(NeuralNetworkModel.allAvailable.count >= NeuralNetworkModel.allCases.count)
        for model in NeuralNetworkModel.allCases {
            #expect(NeuralNetworkModel.allAvailable.contains(model))
        }
    }

    @Test func catalogEntriesAreNotMarkedCustom() {
        for model in NeuralNetworkModel.allCases {
            #expect(model.isCustom == false)
            #expect(model.subdirectory == nil)
        }
    }

    @Test func catalogPathsAreUnchangedByTheSubdirectoryField() {
        // Regression guard: adding `subdirectory` must not move any existing
        // download, whose file already sits in Documents' root.
        let official = NeuralNetworkModel.allCases.first { $0.fileName == "official.bin.gz" }
        #expect(official?.downloadedURL
                == URL.documentsDirectory.appendingPathComponent("official.bin.gz"))
    }
}

// MARK: - Settings-key inventories

/// These pin the two key lists that `CustomModelImporter.delete` sweeps against
/// the code that actually writes them. The keys are unreclaimable once orphaned
/// — a re-import of the very same file gets a fresh uuid filename — so a key
/// added to `BackendSettings` without being added to `persistedKeys` would leak
/// silently and forever.
struct CustomModelSettingsSweepTests {

    private func makeModel(_ fileName: String) -> NeuralNetworkModel {
        NeuralNetworkModel(title: "Sweep Probe",
                           description: "",
                           url: "",
                           fileName: fileName,
                           fileSize: 1,
                           subdirectory: CustomModelStore.subdirectoryName,
                           isCustom: true)
    }

    @Test func everyKeyBackendSettingsWritesIsListedForDeletion() {
        // A unique filename per run so this never collides with real settings
        // in the shared standard suite that BackendSettings hardcodes.
        let fileName = "custom-sweep-\(UUID().uuidString.lowercased()).bin.gz"
        var settings = BackendSettings(model: makeModel(fileName))

        settings.backend = .mlxGPU
        settings.numSearchThreads = 7
        settings.mlxBoardSize = .thirteen
        settings.tunerFull = true
        settings.reTune = true

        let listed = BackendSettings.persistedKeys(forFileName: fileName)
        let written = UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasSuffix("_\(fileName)") }

        #expect(!written.isEmpty)
        for key in written {
            #expect(listed.contains(key), "\(key) is written but not swept on delete")
        }

        for key in listed { UserDefaults.standard.removeObject(forKey: key) }
        #expect(UserDefaults.standard.dictionaryRepresentation().keys
            .filter { $0.hasSuffix("_\(fileName)") }.isEmpty)
    }

    @Test func hasherMemoKeysCoverTheNamesItWrites() {
        let fileName = "custom-hash-\(UUID().uuidString.lowercased()).bin.gz"
        let keys = BinFileHasher.memoKeys(forFileName: fileName)
        #expect(keys.contains("binFileSha256_\(fileName)"))
        #expect(keys.contains("binFileSize_\(fileName)"))
        #expect(keys.contains("binFileMtime_\(fileName)"))
    }
}
