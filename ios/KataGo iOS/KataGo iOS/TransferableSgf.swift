//
//  TransferableSgf.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/8/25.
//

import SwiftUI

struct TransferableSgf: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .text) { sgf in
            sgf.content.data(using: .utf8) ?? Data()
        }
        .suggestedFileName { sgf in
            "\(sgf.name).sgf"
        }
    }

    public var name: String
    public var content: String
}
