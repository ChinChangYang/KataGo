//
//  RankCatalogTests.swift
//  KataGo iOSTests
//
//  The rank ladder's grouping, shared by the iOS long-press menu, the Mac
//  rank menu and the tvOS New Game chooser. Asserted against
//  `HumanSLModel.profileKinds` / `allProfiles` rather than literals, so a
//  ladder change fails in one place.
//

import Testing
@testable import KataGoUICore

struct RankCatalogTests {
    @Test func theGroupsPartitionTheKindsExactlyOnce() {
        let grouped = [RankCatalog.aiProfile] + RankCatalog.dan + RankCatalog.kyu + [RankCatalog.proKind]
        #expect(grouped == HumanSLModel.profileKinds)
    }

    @Test func proEntriesAreEveryProKey() {
        let proKeys = HumanSLModel.allProfiles.filter { $0.hasPrefix("Pro ") }
        #expect(RankCatalog.pro.map(\.profile) == proKeys)
    }

    @Test func theLaddersKeepTheirOrder() {
        #expect(RankCatalog.aiProfile == "AI")
        #expect(RankCatalog.dan.first == "9d")
        #expect(RankCatalog.dan.last == "1d")
        #expect(RankCatalog.dan.count == 9)
        #expect(RankCatalog.kyu.first == "1k")
        #expect(RankCatalog.kyu.last == "25k")
        #expect(RankCatalog.kyu.count == 25)
        #expect(RankCatalog.pro.first?.profile == "Pro 1800")
        #expect(RankCatalog.pro.last?.profile == "Pro 2023")
    }

    /// A rank picked from a menu keeps the side's style year; the side's
    /// current pick is the one wearing the checkmark, whatever its year.
    @Test func aRankPickKeepsTheSidesYear() {
        #expect(RankCatalog.profile(choosing: "3d", from: "5k 2019") == "3d 2019")
        #expect(RankCatalog.profile(choosing: "3d", from: "Pro 1850") == "3d 2016")
        #expect(RankCatalog.profile(choosing: "3d", from: "AI") == "3d 2016")
        #expect(RankCatalog.profile(choosing: "AI", from: "5k 2019") == "AI")
        #expect(RankCatalog.profile(choosing: "3d", from: "garbage") == "3d 2016")
        #expect(RankCatalog.isCurrent(kind: "5k", current: "5k 2019"))
        #expect(!RankCatalog.isCurrent(kind: "5k", current: "5d 2019"))
        #expect(RankCatalog.isCurrent(kind: "AI", current: "AI"))
        #expect(!RankCatalog.isCurrent(kind: "Pro", current: "AI"))
        #expect(RankCatalog.isCurrent(kind: "Pro", current: "Pro 1997"))
    }

    /// A year picked from a chooser keeps the side's kind, clamped into the
    /// kind's range; Full Strength has no year, so it stays Full Strength.
    @Test func aYearPickKeepsTheSidesKind() {
        #expect(RankCatalog.profile(choosingYear: 2019, from: "5k 2016") == "5k 2019")
        #expect(RankCatalog.profile(choosingYear: 2019, from: "5k") == "5k 2019")
        #expect(RankCatalog.profile(choosingYear: 2019, from: "Pro 1850") == "Pro 2019")
        #expect(RankCatalog.profile(choosingYear: 1850, from: "5k 2019") == "5k 2016")
        #expect(RankCatalog.profile(choosingYear: 2019, from: "AI") == "AI")
        #expect(RankCatalog.profile(choosingYear: 2019, from: "garbage") == "AI")
    }

    @Test func yearLabelsAreVerbatim() {
        #expect(RankCatalog.rankYears == Array(2016...2023))
        #expect(RankCatalog.yearLabel(2016) == "2016")
    }

    @Test func proYearsBucketByDecade() {
        #expect(RankCatalog.decades.first == 1800)
        #expect(RankCatalog.decades.last == 2020)
        #expect(RankCatalog.decades == RankCatalog.decades.sorted())
        let nineties = RankCatalog.entries(inDecade: 1990)
        #expect(nineties.map(\.year) == Array(1990...1999))
        #expect(nineties.first?.profile == "Pro 1990")
        // The last decade is partial: 2020 through 2023.
        #expect(RankCatalog.entries(inDecade: 2020).map(\.year) == [2020, 2021, 2022, 2023])
        // Every pro year lands in exactly one decade bucket.
        let bucketed = RankCatalog.decades.flatMap { RankCatalog.entries(inDecade: $0) }
        #expect(bucketed.map(\.profile) == RankCatalog.pro.map(\.profile))
    }

    @Test func decadeLookupAndLabelsAreVerbatim() {
        #expect(RankCatalog.decade(containing: "Pro 1997") == 1990)
        #expect(RankCatalog.decade(containing: "5d 2016") == nil)
        #expect(RankCatalog.decade(containing: "AI") == nil)
        #expect(RankCatalog.decadeLabel(1990) == "1990s")
        #expect(RankCatalog.ProEntry(year: 1997, profile: "Pro 1997").label == "1997")
        #expect(RankCatalog.title(for: "AI") == "Full Strength (AI)")
        #expect(RankCatalog.title(for: "5d 2016") == "5d 2016")
        #expect(RankCatalog.title(for: "Pro") == "Pro")
    }
}
