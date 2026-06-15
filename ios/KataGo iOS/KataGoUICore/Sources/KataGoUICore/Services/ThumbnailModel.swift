//
//  ThumbnailModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/3/31.
//

import Foundation

@Observable
public class ThumbnailModel {
    public static let smallSize: CGFloat = 64.0
    public static let largeSize: CGFloat = 128.0
    public var isLarge: Bool = UserDefaults.standard.bool(forKey: "isLargeThumbnail")
    public var isGameListViewAppeared: Bool = false

    public init() {}

    public var title: String {
        return isLarge ? "Small Thumbnails" : "Large Thumbnails"
    }

    public var width: CGFloat {
        return isLarge ? Self.largeSize : Self.smallSize
    }

    public var height: CGFloat {
        return width
    }

    public func save() {
        UserDefaults.standard.set(isLarge, forKey: "isLargeThumbnail")
    }
}
