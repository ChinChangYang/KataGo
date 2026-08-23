//
//  VisionGamePickerItem.swift
//  KataGoUICore
//
//  Pure row model for the visionOS ornament's Games picker, built from a
//  GameRecord's cheap stored fields (no SGF parse, no engine). A row is
//  selectable when its board has a bundled 3D asset — that is the only thing
//  the volume genuinely cannot draw. A board that renders but exceeds the
//  launched NN buffer IS selectable: it opens, draws, and reports *Held*
//  (the engine is simply never fed it), and the row's caption says which of
//  the two exits applies. An unknown size stays selectable (optimistic) —
//  the openGame handler re-derives the size from the SGF and gates
//  authoritatively.
//

import Foundation

public struct VisionGamePickerItem: Equatable, Sendable {
    public let title: String
    /// "3:24 PM · 19×19" — either part is omitted when unknown.
    public let detailText: String
    public let isSelectable: Bool
    /// The board renders fine, exceeds the launched NN buffer, but fits
    /// within the active net's own cap — the row caption points at the Max
    /// Board Size setting (raising it works).
    public let needsLargerBoardSetting: Bool
    /// The board renders fine but exceeds the active net's cap (nnLen —
    /// the Lionffen class is capped at 19): no Max Board Size choice can
    /// ever fit it, so the caption points at switching the neural net.
    public let needsDifferentNet: Bool

    public static func make(name: String,
                            lastModificationDate: Date?,
                            width: Int?,
                            height: Int?,
                            maxBoardLength: Int,
                            modelBoardCap: Int = 37,
                            now: Date = .now) -> VisionGamePickerItem {
        let sizeText: String?
        let isSelectable: Bool
        let needsLargerBoardSetting: Bool
        let needsDifferentNet: Bool
        if let width, let height {
            sizeText = "\(width)×\(height)"
            let supported = visionBoardIsSupported(width: width, height: height)
            let fits = boardFits(width: width, height: height,
                                 maxBoardLength: maxBoardLength)
            let raisable = boardFits(width: width, height: height,
                                     maxBoardLength: modelBoardCap)
            // Size is NOT part of selectability any more: over-cap boards open
            // and report Held. Geometry still is — there is no asset to draw.
            isSelectable = supported
            needsLargerBoardSetting = supported && !fits && raisable
            needsDifferentNet = supported && !fits && !raisable
        } else {
            sizeText = nil
            isSelectable = true
            needsLargerBoardSetting = false
            needsDifferentNet = false
        }

        let dateText = lastModificationDate?.shortened(now: now)
        let detailText = [dateText, sizeText].compactMap { $0 }.joined(separator: " · ")
        return VisionGamePickerItem(title: name,
                                    detailText: detailText,
                                    isSelectable: isSelectable,
                                    needsLargerBoardSetting: needsLargerBoardSetting,
                                    needsDifferentNet: needsDifferentNet)
    }
}
