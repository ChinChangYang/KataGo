//
//  ReportCollectorTests.swift
//  KataGo AnytimeTests
//

import Testing
@testable import KataGo_Anytime
@testable import KataGoUICore

struct ReportCollectorTests {
    @Test func staleLinesBeforeFirstAckAreDropped() {
        let c = ReportCollector()
        c.willSend(stage: nil)              // kata-set-param
        c.willSend(stage: .snapshot)        // kata-analyze
        c.ingest(line: "info move D4 visits 99 ...")   // stale live-analysis line
        c.ingest(line: "= ")                            // set-param ack
        c.ingest(line: "info move D4 visits 100 ...")  // still stale (analyze header not seen)
        #expect(c.latestLine(for: .snapshot) == nil)
        c.ingest(line: "=")                             // analyze response header
        c.ingest(line: "info move Q16 visits 7 ...")
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 7 ...")
    }

    @Test func latestLineWinsWithinStage() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info move Q16 visits 7 ...")
        c.ingest(line: "info move Q16 visits 30 ...")
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 30 ...")
    }

    @Test func nonAnalyzeAckEndsTheStage() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info move Q16 visits 7 ...")
        c.willSend(stage: nil)              // stop
        c.ingest(line: "")                  // cancelled-analyze terminator — ignored
        c.ingest(line: "info move Q16 visits 9 ...")   // in-flight before stop ack: still snapshot
        c.ingest(line: "= ")                // stop ack → stage ends
        c.ingest(line: "info move Z9 visits 1 ...")    // stray → dropped
        #expect(c.latestLine(for: .snapshot) == "info move Q16 visits 9 ...")
    }

    @Test func stagesAttributeIndependently() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info snapshot-line")
        c.willSend(stage: nil)                       // stop
        c.ingest(line: "= ")
        c.willSend(stage: .tenuki(0))                // next analyze
        c.ingest(line: "=")
        c.ingest(line: "info tenuki-line")
        #expect(c.latestLine(for: .snapshot) == "info snapshot-line")
        #expect(c.latestLine(for: .tenuki(0)) == "info tenuki-line")
        #expect(c.latestLine(for: .tenuki(1)) == nil)
    }

    @Test func errorLineSetsSawError() {
        let c = ReportCollector()
        #expect(c.sawError == false)
        c.ingest(line: "? illegal move")
        #expect(c.sawError == true)
    }

    @Test func resetClearsState() {
        let c = ReportCollector()
        c.willSend(stage: .snapshot)
        c.ingest(line: "=")
        c.ingest(line: "info x")
        c.ingest(line: "? boom")
        c.reset()
        #expect(c.latestLine(for: .snapshot) == nil)
        #expect(c.sawError == false)
    }
}
