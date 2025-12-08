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
            cleanUpSgfFiles()
            return try createTransferredFile(from: sgf)
        } importing: { received in
            let file = received.file
            let name = file.deletingPathExtension().lastPathComponent
            let content = try String(contentsOf: file, encoding: .utf8)

            return TransferableSgf(
                name: name,
                content: content
            )
        }

        FileRepresentation(exportedContentType: .utf8PlainText) { sgf in
            cleanUpSgfFiles()
            return try createTransferredFile(from: sgf)
        }
    }

    static func createTransferredFile(from sgf: TransferableSgf) throws -> SentTransferredFile {

        let fileName = sgf.name.isEmpty ? "KataGoAnytime" : sgf.name
        let file = URL.documentsDirectory.appendingPathComponent("\(fileName).sgf")

        try sgf.content.write(
            to: file,
            atomically: false,
            encoding: .utf8
        )

        return SentTransferredFile(file)
    }

    static func cleanUpSgfFiles() {
        let fileManager = FileManager.default

        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: URL.documentsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for fileURL in fileURLs {
            if fileURL.pathExtension == "sgf" {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    public var name: String
    public var content: String
}
