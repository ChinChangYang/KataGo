//
//  CoalescedTriggerTests.swift
//  KataGo iOSTests
//
//  Deterministic coverage for the debounce/coalescing primitive that the macOS
//  LibraryStore uses to absorb CloudKit's burst of `.NSPersistentStoreRemoteChange`
//  notifications. These tests pin the coalescing + cancellation logic; they do
//  NOT (and cannot) prove the OS posts the notification on a real CloudKit merge
//  — that is covered by the manual two-device cross-device test on a build that
//  talks to the Production CloudKit environment.
//

import Testing
@testable import KataGoUICore

/// A main-actor reference counter so the scheduled `@MainActor` closures mutate
/// shared state through an immutable binding (avoids capturing a mutable `var`).
@MainActor
private final class Recorder {
    var count = 0
    var log: [String] = []
}

@MainActor
@Suite("CoalescedTrigger")
struct CoalescedTriggerTests {

    @Test("Runs the work once after a single schedule")
    func runsOnceAfterSingleSchedule() async {
        let trigger = CoalescedTrigger(delay: .milliseconds(1))
        let recorder = Recorder()
        trigger.schedule { recorder.count += 1 }
        await trigger.settle()
        #expect(recorder.count == 1)
    }

    @Test("Collapses a burst of rapid schedules into a single run")
    func collapsesBurstToSingleRun() async {
        let trigger = CoalescedTrigger(delay: .milliseconds(1))
        let recorder = Recorder()
        for _ in 0..<10 { trigger.schedule { recorder.count += 1 } }
        await trigger.settle()
        #expect(recorder.count == 1)
    }

    @Test("A superseded run never executes (cancellation guard holds)")
    func supersededRunNeverExecutes() async {
        let trigger = CoalescedTrigger(delay: .milliseconds(1))
        let recorder = Recorder()
        trigger.schedule { recorder.log.append("first") }
        trigger.schedule { recorder.log.append("second") }  // supersedes "first"
        await trigger.settle()
        #expect(recorder.log == ["second"])
    }

    @Test("cancel() suppresses a pending run")
    func cancelSuppressesPendingRun() async {
        let trigger = CoalescedTrigger(delay: .milliseconds(1))
        let recorder = Recorder()
        trigger.schedule { recorder.count += 1 }
        trigger.cancel()
        await trigger.settle()
        #expect(recorder.count == 0)
    }

    @Test("Runs again after a previous run has settled")
    func runsAgainAfterSettle() async {
        let trigger = CoalescedTrigger(delay: .milliseconds(1))
        let recorder = Recorder()
        trigger.schedule { recorder.count += 1 }
        await trigger.settle()
        trigger.schedule { recorder.count += 1 }
        await trigger.settle()
        #expect(recorder.count == 2)
    }
}
