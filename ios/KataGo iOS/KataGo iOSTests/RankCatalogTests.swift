//
//  RankCatalogTests.swift
//  KataGo iOSTests
//
//  The rank ladder's grouping, shared by the iOS long-press menu, the Mac
//  rank menu and the tvOS New Game chooser. Asserted against
//  `HumanSLModel.allProfiles` rather than literals, so a ladder change fails
//  in one place.
//

import Testing
@testable import KataGoUICore

struct RankCatalogTests {
    @Test func theGroupsPartitionTheLadderExactlyOnce() {
        let grouped = [RankCatalog.aiProfile] + RankCatalog.dan + RankCatalog.kyu
            + RankCatalog.pro.map(\.profile)
        #expect(grouped.count == HumanSLModel.allProfiles.count)
        #expect(Set(grouped) == Set(HumanSLModel.allProfiles))
        #expect(Set(grouped).count == grouped.count)
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
        #expect(RankCatalog.decade(containing: "5d") == nil)
        #expect(RankCatalog.decade(containing: "AI") == nil)
        #expect(RankCatalog.decadeLabel(1990) == "1990s")
        #expect(RankCatalog.ProEntry(year: 1997, profile: "Pro 1997").label == "1997")
        #expect(RankCatalog.title(for: "AI") == "Full Strength (AI)")
        #expect(RankCatalog.title(for: "5d") == "5d")
    }
}
