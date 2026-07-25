//
//  SafariWebExtensionHandler.swift
//  KataGoAnytimeSafariExtIOS
//
//  NSExtensionPrincipalClass. Decodes one wire request, hands it to
//  IOSAnalysisService off the main queue, and completes the request. Kept thin
//  on purpose: on iOS this process is launched per message and torn down when
//  idle, so no state is assumed to survive between calls.
//

import Foundation
import SafariServices
import os
import KataGoAnalysisKit

private let handlerLog = Logger(subsystem: "chinchangyang.KataGo-iOS.tw.safariweb",
                                category: "handler")

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    /// NSExtensionContext is not Sendable; box it for the queue hop.
    private final class ContextBox: @unchecked Sendable {
        let context: NSExtensionContext
        init(_ context: NSExtensionContext) { self.context = context }
    }

    func beginRequest(with context: NSExtensionContext) {
        let box = ContextBox(context)
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        guard let message else {
            complete(box, with: .error(code: .badRequest, message: "empty message",
                                       retryable: false))
            return
        }

        let request: AnalysisRequest
        do {
            request = try AnalysisWireCoding.request(fromDictionary: message)
        } catch {
            handlerLog.error("undecodable request: \(String(describing: error), privacy: .public)")
            complete(box, with: .error(code: .badRequest, message: "undecodable request",
                                       retryable: false))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let service = IOSAnalysisService.shared
            let response = service.handle(request)
            // `.opened` carries no payload on the shared wire (macOS opens the
            // URL itself). iOS extensions cannot open URLs, so pass the deep
            // link back for the content script to navigate to.
            var extra: [String: Any] = [:]
            if case .opened = response, let url = service.lastHandoffURL {
                extra["url"] = url
            }
            // Engine identity rides along with ordinary replies (iOS-only keys,
            // so the shared AnalysisWire — which macOS also compiles and caches
            // against — stays untouched). The panel shows these behind a tap on
            // its logo; piggybacking avoids a second round trip, and nothing
            // here can start the engine.
            let engine = IOSEngineController.shared
            extra["engineModel"] = engine.engineModelName
            if let version = engine.engineVersion {
                extra["engineVersion"] = version
            }
            self.complete(box, with: response, extra: extra)
        }
    }

    private func complete(_ box: ContextBox,
                          with response: AnalysisResponse,
                          extra: [String: Any] = [:]) {
        var payload: [String: Any]
        do {
            payload = try AnalysisWireCoding.dictionary(from: response)
        } catch {
            payload = ["type": "error", "code": "badRequest",
                       "message": "response encoding failed", "retryable": false]
        }
        payload.merge(extra) { _, new in new }

        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: payload]
        box.context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
