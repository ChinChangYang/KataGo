//
//  OwnershipBudgetTests.swift
//  KataGo iOSTests
//
//  Pins the write-time ownership cap that keeps a GameRecord under CloudKit's
//  ~1 MB per-record limit (the prevention for the iCloud export wedge described
//  in project_mac_icloud_list_live_refresh). These tests exercise the pure
//  eviction logic directly; the end-to-end "a long analyzed game stays
//  uploadable" behaviour is covered by the live two-device sync test.
//

import Testing
@testable import KataGoUICore

@Suite("OwnershipBudget")
struct OwnershipBudgetTests {

    /// Standard board point count; 600_000 / (2 * 361 * 6) = 138 retained indices.
    private let points19 = 19 * 19

    // Builds an ownership-shaped dictionary: one full-board Float array per index.
    private func sampleOwnership(indices: Range<Int>, points: Int) -> [Int: [Float]] {
        var dict: [Int: [Float]] = [:]
        for index in indices {
            dict[index] = Array(repeating: 0.5, count: points)
        }
        return dict
    }

    @Test("Under-budget dictionaries are returned unchanged")
    func underBudgetUnchanged() {
        let whiteness = sampleOwnership(indices: 0..<10, points: points19)
        let scales = sampleOwnership(indices: 0..<10, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: 9)
        #expect(out.whiteness.count == 10)
        #expect(out.scales.count == 10)
        #expect(Set(out.whiteness.keys) == Set(0..<10))
    }

    @Test("Over-budget evicts the oldest indices down to the cap")
    func overBudgetEvictsOldest() {
        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: points19)
        let total = limit + 50
        let whiteness = sampleOwnership(indices: 0..<total, points: points19)
        let scales = sampleOwnership(indices: 0..<total, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: total - 1)
        #expect(out.whiteness.count == limit)
        #expect(out.scales.count == limit)
        // The most-recent `limit` indices survive; the oldest 50 are gone.
        #expect(Set(out.whiteness.keys) == Set((total - limit)..<total))
        #expect(out.whiteness[0] == nil)
    }

    @Test("Both dictionaries are trimmed to an identical key set")
    func dictionariesStayConsistent() {
        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: points19)
        let total = limit + 20
        let whiteness = sampleOwnership(indices: 0..<total, points: points19)
        let scales = sampleOwnership(indices: 0..<total, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: total - 1)
        #expect(Set(out.whiteness.keys) == Set(out.scales.keys))
    }

    @Test("The just-analyzed index always survives, even when it is old")
    func protectedOldIndexSurvives() {
        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: points19)
        let total = limit + 30
        // Simulate scrubbing back and re-analyzing an OLD move (index 0).
        let whiteness = sampleOwnership(indices: 0..<total, points: points19)
        let scales = sampleOwnership(indices: 0..<total, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: 0)
        #expect(out.whiteness.count == limit)
        #expect(out.whiteness[0] != nil)   // protected index retained
        #expect(out.scales[0] != nil)
    }

    @Test("A protected index in the middle of the range survives a scrub-back re-analysis")
    func protectedMiddleIndexSurvives() {
        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: points19)
        let total = limit + 40
        let middle = total / 2   // not among the most-recent `limit` indices
        let whiteness = sampleOwnership(indices: 0..<total, points: points19)
        let scales = sampleOwnership(indices: 0..<total, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: middle)
        #expect(out.whiteness.count == limit)
        #expect(out.whiteness[middle] != nil)   // protected middle index retained
        #expect(out.scales[middle] != nil)
        // The window is the protected index plus the most-recent (limit - 1) others.
        #expect(out.whiteness[total - 1] != nil)
    }

    @Test("Diverged inputs are each filtered to the window without crashing or exceeding the cap")
    func mismatchedKeysHandledDefensively() {
        // The two dicts never diverge at the real call site, but the defensive
        // union path must still keep each within the cap, retain the protected
        // index wherever it exists, and never trap.
        let limit = OwnershipBudget.maxRetainedIndices(pointsPerMove: points19)
        let total = limit + 25
        var whiteness = sampleOwnership(indices: 0..<total, points: points19)
        var scales = sampleOwnership(indices: 0..<total, points: points19)
        whiteness[total - 1] = nil   // most-recent key absent from whiteness only
        scales[0] = nil              // oldest key absent from scales only
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: total - 1)
        #expect(out.whiteness.count <= limit)
        #expect(out.scales.count <= limit)
        #expect(out.scales[total - 1] != nil)   // protected index kept where present
        #expect(out.whiteness[0] == nil)        // oldest still evicted
    }

    @Test("Result stays within the combined byte budget")
    func resultWithinByteBudget() {
        let total = 500
        let whiteness = sampleOwnership(indices: 0..<total, points: points19)
        let scales = sampleOwnership(indices: 0..<total, points: points19)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: points19, keeping: total - 1)
        let estimatedBytes =
            (out.whiteness.count + out.scales.count) * points19 * OwnershipBudget.estimatedBytesPerFloat
        #expect(estimatedBytes <= OwnershipBudget.combinedByteBudget)
    }

    @Test("Larger boards retain proportionally fewer indices")
    func largerBoardsRetainFewer() {
        let small = OwnershipBudget.maxRetainedIndices(pointsPerMove: 9 * 9)
        let mid = OwnershipBudget.maxRetainedIndices(pointsPerMove: 19 * 19)
        let large = OwnershipBudget.maxRetainedIndices(pointsPerMove: 37 * 37)
        #expect(small > mid)
        #expect(mid > large)
        #expect(large >= 1)
    }

    @Test("The retained count never drops below 1; the protected index is the lone survivor")
    func capFloorsAtOne() {
        let absurdPoints = 10_000_000
        #expect(OwnershipBudget.maxRetainedIndices(pointsPerMove: absurdPoints) == 1)
        let whiteness = sampleOwnership(indices: 0..<3, points: 4)
        let scales = sampleOwnership(indices: 0..<3, points: 4)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: absurdPoints, keeping: 1)
        #expect(out.whiteness.count == 1)
        #expect(out.whiteness[1] != nil)
        #expect(out.scales.count == 1)
        #expect(out.scales[1] != nil)
    }

    @Test("A non-positive board size disables pruning (no division by zero)")
    func nonPositivePointsKeepsEverything() {
        #expect(OwnershipBudget.maxRetainedIndices(pointsPerMove: 0) == .max)
        let whiteness = sampleOwnership(indices: 0..<5, points: 1)
        let scales = sampleOwnership(indices: 0..<5, points: 1)
        let out = OwnershipBudget.pruned(
            whiteness: whiteness, scales: scales, pointsPerMove: 0, keeping: 4)
        #expect(out.whiteness.count == 5)
        #expect(out.scales.count == 5)
    }
}
