//
//  TransferableSgf.swift
//  KataGo Anytime
//
//  Created by Chin-Chang Yang on 2025/8/25.
//

import SwiftUI

struct TransferableSgf: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .utf8PlainText) { sgf in
            try createTransferredFile(from: sgf)
        } importing: { received in
            let content = try String(contentsOf: received.file, encoding: .utf8)

            return TransferableSgf(
                name: "",
                content: content
            )
        }

        FileRepresentation(exportedContentType: .utf8PlainText) { sgf in
            return try createTransferredFile(from: sgf)
        }
    }

    static func createTransferredFile(from sgf: TransferableSgf) throws -> SentTransferredFile {
        let supportDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let file = supportDirectory.appendingPathComponent("KataGoAnytime.sgf")

        try sgf.content.write(
            to: file,
            atomically: false,
            encoding: .utf8
        )

        return SentTransferredFile(file)
    }

    public var name: String
    public var content: String
}
