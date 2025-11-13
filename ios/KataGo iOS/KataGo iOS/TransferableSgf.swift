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
        let supportDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let fileName = sgf.name.isEmpty ? "KataGoAnytime" : sgf.name
        let file = supportDirectory.appendingPathComponent("\(fileName).sgf")

        try sgf.content.write(
            to: file,
            atomically: false,
            encoding: .utf8
        )

        return SentTransferredFile(file)
    }

    static func cleanUpSgfFiles() {
        let fileManager = FileManager.default

        guard let supportDirectory = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return
        }

        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: supportDirectory,
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
