//
//  SafariWebExtensionHandler.swift
//  KataGoAnytimeSafariExt
//
//  Native side of the Safari web extension: decodes each native message into
//  the analysis wire schema and routes it to the AnalysisJobRunner. Requests
//  are answered from a background queue because a turn may block briefly on
//  the runner's lock (engine work itself runs on the runner's own worker
//  thread, never here).
//

import Foundation
import SafariServices
import KataGoAnalysisKit
import os.log

/// NSExtensionContext is not Sendable; requests are completed from a
/// background queue after the runner produces a response.
private struct ContextBox: @unchecked Sendable {
    let context: NSExtensionContext
}

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?
            .userInfo?[SFExtensionMessageKey] as? [String: Any]
        // Decode before the hop: AnalysisRequest is Sendable, the raw
        // [String: Any] is not, so only the decoded value crosses. The decode
        // is JSONSerialization + JSONDecoder on a small payload — no I/O and no
        // locks. (The runner's lock, the reason for the hop, is still taken
        // off this thread.)
        let request = message.flatMap { try? AnalysisWireCoding.request(fromDictionary: $0) }
        let box = ContextBox(context: context)

        DispatchQueue.global(qos: .userInitiated).async {
            let response: AnalysisResponse
            if let request {
                response = AnalysisJobRunner.shared.handle(request)
            } else {
                response = .error(code: .badRequest,
                                  message: "unrecognized message shape",
                                  retryable: false)
            }
            let payload = (try? AnalysisWireCoding.dictionary(from: response))
                ?? ["type": "error", "code": "badRequest",
                    "message": "response encoding failed", "retryable": false]
            let item = NSExtensionItem()
            item.userInfo = [SFExtensionMessageKey: payload]
            box.context.completeRequest(returningItems: [item])
        }
    }
}
