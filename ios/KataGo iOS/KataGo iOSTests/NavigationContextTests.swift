//
//  NavigationContextTests.swift
//  KataGo iOSTests
//
//  Created by Chin-Chang Yang on 2024/8/17.
//

import Testing
@testable import KataGo_Anytime

struct NavigationContextTests {

    @Test func nilGameRecord() async throws {
        let navigationContext = NavigationContext()
        #expect(navigationContext.selectedGameRecord == nil)
    }

}
