//
//  VisionModelListItem.swift
//  KataGoUICore
//
//  Pure row view-model behind the visionOS Models card list — the Vision
//  mirror of iOS ModelPickerView rows: one item per visible,
//  platform-eligible registry model (visionOS restricts nothing), the
//  active indicator keyed by title (the ModelRunnerView.* persistence
//  contract stores titles), and the green Core ML cache-ready checkmark
//  keyed by fileName (CoreMLCacheReadiness vends fileNames).
//

import Foundation

public struct VisionModelListItem: Equatable, Sendable, Identifiable {
    public let title: String
    public let fileName: String
    public let isActive: Bool
    public let showsReadyCheckmark: Bool

    public var id: String { title }

    public static func makeAll(models: [NeuralNetworkModel] = NeuralNetworkModel.allCases,
                               activeTitle: String,
                               readyFileNames: Set<String>) -> [VisionModelListItem] {
        models
            .filter { $0.visible && $0.isEligibleOnThisPlatform }
            .map { model in
                VisionModelListItem(
                    title: model.title,
                    fileName: model.fileName,
                    isActive: model.title == activeTitle,
                    showsReadyCheckmark: readyFileNames.contains(model.fileName))
            }
    }
}
