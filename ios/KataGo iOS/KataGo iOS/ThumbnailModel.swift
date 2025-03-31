//
//  ThumbnailModel.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/3/31.
//

import Foundation

@Observable
class ThumbnailModel {
    static let smallSize: CGFloat = 64.0
    static let largeSize: CGFloat = 128.0
    var isLarge: Bool = UserDefaults.standard.bool(forKey: "isLargeThumbnail")

    var title: String {
        return isLarge ? "Small Thumbnails" : "Large Thumbnails"
    }

    var width: CGFloat {
        return isLarge ? Self.largeSize : Self.smallSize
    }

    var height: CGFloat {
        return width
    }

    func save() {
        UserDefaults.standard.set(isLarge, forKey: "isLargeThumbnail")
    }
}
