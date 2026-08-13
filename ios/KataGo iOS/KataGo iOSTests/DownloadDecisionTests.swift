//
//  DownloadDecisionTests.swift
//  KataGo AnytimeTests
//
//  Pins the pure download decisions: Content-Range parsing, the
//  resume/restart/fail rule (including GitHub's non-standard 618), the
//  verification gate, the retry schedule, the NaN-proof progress fraction,
//  and the four-role download button.
//

import Foundation
import Testing
@testable import KataGoUICore

struct ContentRangeHeaderTests {
    @Test func parsesACompleteRange() {
        let parsed = ContentRangeHeader("bytes 200-1023/1024")
        #expect(parsed?.first == 200)
        #expect(parsed?.last == 1023)
        #expect(parsed?.total == 1024)
    }

    @Test func parsesAnUnknownTotal() {
        let parsed = ContentRangeHeader("bytes 0-99/*")
        #expect(parsed?.first == 0)
        #expect(parsed?.total == nil)
    }

    @Test func rejectsJunk() {
        #expect(ContentRangeHeader("items 0-9/10") == nil)
        #expect(ContentRangeHeader("bytes 10-9/100") == nil)
        #expect(ContentRangeHeader("bytes abc/100") == nil)
        #expect(ContentRangeHeader("") == nil)
    }
}

struct ResumeDecisionTests {
    @Test func rangedRequestAcceptsExactly206() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: "bytes 200-1023/1024",
                                             contentLength: 824)
        #expect(decision == .append(expectedTotal: 1024))
    }

    @Test func theFirstChunkIsStillARangedRequest() {
        // Every request the transport makes carries a Range, including the
        // first, so offset 0 must accept a 206 rather than demanding a 200.
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 0,
                                             statusCode: 206,
                                             contentRange: "bytes 0-33554431/240027267",
                                             contentLength: 33_554_432)
        #expect(decision == .append(expectedTotal: 240_027_267))
    }

    @Test func rangedRequestTreats200AsTheWholeAsset() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 200,
                                             contentRange: nil,
                                             contentLength: 4096)
        #expect(decision == .restart(expectedTotal: 4096))
    }

    @Test func rangedRequestRejectsAMisalignedRange() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: "bytes 0-1023/1024",
                                             contentLength: 1024)
        guard case .fail = decision else {
            Issue.record("a 206 starting somewhere else must not be appended")
            return
        }
    }

    @Test func rangedRequestRejects206WithoutAContentRange() {
        let decision = ResumeDecision.decide(sentRange: true,
                                             requestedOffset: 200,
                                             statusCode: 206,
                                             contentRange: nil,
                                             contentLength: 824)
        guard case .fail = decision else {
            Issue.record("a 206 with no Content-Range has no verifiable offset")
            return
        }
    }

    // The one that matters: GitHub release assets answer an expired redirect
    // with 618, which is neither 4xx nor 5xx, and whose 430-byte XML body
    // carries a believable Content-Disposition.
    @Test func expiredJwt618IsNeverABody() {
        let ranged = ResumeDecision.decide(sentRange: true,
                                           requestedOffset: 1_000,
                                           statusCode: 618,
                                           contentRange: nil,
                                           contentLength: 430)
        let fresh = ResumeDecision.decide(sentRange: false,
                                          requestedOffset: 0,
                                          statusCode: 618,
                                          contentRange: nil,
                                          contentLength: 430)
        guard case .fail = ranged, case .fail = fresh else {
            Issue.record("618 must fail on both the fresh and the ranged path")
            return
        }
    }

    @Test func anUnrangedRequestAcceptsOnly200() {
        #expect(ResumeDecision.decide(sentRange: false,
                                      requestedOffset: 0,
                                      statusCode: 200,
                                      contentRange: nil,
                                      contentLength: 99) == .restart(expectedTotal: 99))
        for status in [206, 204, 301, 403, 404, 500, 503] {
            guard case .fail = ResumeDecision.decide(sentRange: false,
                                                     requestedOffset: 0,
                                                     statusCode: status,
                                                     contentRange: nil,
                                                     contentLength: nil) else {
                Issue.record("status \(status) must not be installed as an asset")
                return
            }
        }
    }
}

struct TransferVerificationTests {
    @Test func exactSizePasses() {
        #expect(TransferVerification.check(assembledBytes: 1024, declaredTotal: 1024) == .verified)
    }

    @Test func shortBodyFails() {
        #expect(TransferVerification.check(assembledBytes: 430, declaredTotal: 240_027_267)
                == .sizeMismatch(expected: 240_027_267, actual: 430))
    }

    @Test func longBodyFails() {
        #expect(TransferVerification.check(assembledBytes: 2048, declaredTotal: 1024)
                == .sizeMismatch(expected: 1024, actual: 2048))
    }

    @Test func anUndeclaredTotalLeavesNothingToCheck() {
        #expect(TransferVerification.check(assembledBytes: 7, declaredTotal: nil) == .verified)
        #expect(TransferVerification.check(assembledBytes: 7, declaredTotal: 0) == .verified)
    }
}

struct RetryBackoffTests {
    @Test func threeRetriesThenGiveUp() {
        #expect(RetryBackoff.delay(forAttempt: 0) == 2)
        #expect(RetryBackoff.delay(forAttempt: 1) == 8)
        #expect(RetryBackoff.delay(forAttempt: 2) == 30)
        #expect(RetryBackoff.delay(forAttempt: 3) == nil)
        #expect(RetryBackoff.delay(forAttempt: -1) == nil)
    }
}

struct DownloadProgressMathTests {
    @Test func fractionIsTheObviousRatio() {
        #expect(DownloadProgressMath.fraction(received: 512, total: 1024) == 0.5)
        #expect(DownloadProgressMath.fraction(received: 0, total: 1024) == 0)
        #expect(DownloadProgressMath.fraction(received: 1024, total: 1024) == 1)
    }

    @Test func unknownTotalIsZeroNotNaN() {
        let unknown = DownloadProgressMath.fraction(received: 900, total: nil)
        #expect(unknown == 0)
        #expect(unknown.isFinite)
        let negative = DownloadProgressMath.fraction(received: 900, total: -1)
        #expect(negative == 0)
        #expect(negative.isFinite)
    }

    @Test func overshootIsClamped() {
        #expect(DownloadProgressMath.fraction(received: 5000, total: 1024) == 1)
        #expect(DownloadProgressMath.fraction(received: -5, total: 1024) == 0)
    }
}

struct DownloadButtonRoleTests {
    @Test func onDiskAlwaysPlays() {
        for state in DownloadState.allCases {
            #expect(DownloadButtonRole.role(isOnDisk: true, state: state, hasPartial: true) == .play)
        }
    }

    @Test func runningAndQueuedBothOfferStop() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .transferring, hasPartial: true) == .pause)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .waiting, hasPartial: false) == .pause)
    }

    @Test func stoppedWithBytesOffersResume() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .paused, hasPartial: true) == .resume)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .interrupted, hasPartial: true) == .resume)
    }

    @Test func stoppedWithNothingOffersAFreshDownload() {
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .paused, hasPartial: false) == .download)
        #expect(DownloadButtonRole.role(isOnDisk: false, state: .idle, hasPartial: false) == .download)
    }

    @Test func downloadAndResumeShareAGlyphButNotAVoice() {
        #expect(DownloadButtonRole.download.systemImageName == DownloadButtonRole.resume.systemImageName)
        #expect(DownloadButtonRole.download.actionTitle != DownloadButtonRole.resume.actionTitle)
    }
}

@MainActor
struct DownloadKillSwitchTests {
    // The UI-test target links no package products, so `PortraitUITestCase`
    // and `KataGo_iOSUITestsLaunchTests` spell this argument as a literal.
    // If the constant ever changes, the suite silently stops being inert and
    // starts issuing real network traffic — so pin the two together here.
    //
    // `DownloadCenter` is `@MainActor`, so its `static let` members inherit
    // that isolation — this struct has to carry `@MainActor` too, or the
    // `#expect` macro expansion cannot reference `disableLaunchArgument`
    // from a nonisolated context. (House precedent: `GhostCursorModelTests`
    // in this same target for the same reason.) Every other struct in this
    // file stays nonisolated on purpose — the pure decision types it tests
    // have no isolation of their own.
    @Test func theUITestLaunchArgumentMatchesTheLiteralTheSuiteUses() {
        #expect(DownloadCenter.disableLaunchArgument == "--uitest-disable-downloads")
    }
}
