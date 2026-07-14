//
//  VisionGamePickerItem.swift
//  KataGoUICore
//
//  Pure row model for the visionOS ornament's Games picker, built from a
//  GameRecord's cheap stored fields (no SGF parse, no engine). A row is
//  selectable when its board has a bundled 3D asset AND fits the launched
//  engine's NN buffer; an unknown size stays selectable (optimistic) — the
//  openGame handler re-derives the size from the SGF and gates
//  authoritatively before any engine load.
//

import Foundation

public struct VisionGamePickerItem: Equatable, Sendable {
    public let title: String
    /// "3:24 PM · 19×19" — either part is omitted when unknown.
    public let detailText: String
    public let isSelectable: Bool
    /// The board renders fine but exceeds the launched NN buffer — the row
    /// caption points at the Max Board Size setting.
    public let needsLargerBoardSetting: Bool

    public static func make(name: String,
                            lastModificationDate: Date?,
                            width: Int?,
                            height: Int?,
                            maxBoardLength: Int,
                            now: Date = .now) -> VisionGamePickerItem {
        let sizeText: String?
        let isSelectable: Bool
        let needsLargerBoardSetting: Bool
        if let width, let height {
            sizeText = "\(width)×\(height)"
            let supported = visionBoardIsSupported(width: width, height: height)
            let fits = boardFits(width: width, height: height,
                                 maxBoardLength: maxBoardLength)
            isSelectable = supported && fits
            needsLargerBoardSetting = supported && !fits
        } else {
            sizeText = nil
            isSelectable = true
            needsLargerBoardSetting = false
        }

        let dateText = lastModificationDate?.shortened(now: now)
        let detailText = [dateText, sizeText].compactMap { $0 }.joined(separator: " · ")
        return VisionGamePickerItem(title: name,
                                    detailText: detailText,
                                    isSelectable: isSelectable,
                                    needsLargerBoardSetting: needsLargerBoardSetting)
    }
}
