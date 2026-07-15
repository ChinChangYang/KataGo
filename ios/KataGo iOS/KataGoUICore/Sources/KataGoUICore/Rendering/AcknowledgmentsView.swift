//
//  AcknowledgmentsView.swift
//  KataGoUICore
//
//  Shared licenses screen (promoted from the iOS app target so macOS,
//  tvOS, and visionOS can render the same registry — the TestFlight EULA
//  §4 points every platform at "Settings > Open-Source Licenses").
//  Vanilla SwiftUI: iOS/visionOS push it in their settings stacks, macOS
//  hosts it via NSHostingController, tvOS pushes it from TVSettingsScreen.
//

import SwiftUI

/// Lists every third-party component shipped in the app, with its license.
public struct AcknowledgmentsView: View {
    public init() {}

    public var body: some View {
        List(ThirdPartyLicense.shipped) { license in
            NavigationLink {
                LicenseDetailView(license: license)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(license.name)
                    Text(license.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(license.name)
        }
        .navigationTitle("Open-Source Licenses")
    }
}

/// Shows one component's full, verbatim license text.
public struct LicenseDetailView: View {
    public let license: ThirdPartyLicense

    public init(license: ThirdPartyLicense) {
        self.license = license
    }

    public var body: some View {
        ScrollView {
            licenseText
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(license.name)
    }

    /// tvOS: text selection is unavailable, and a ScrollView of plain Text
    /// cannot scroll without a focusable element for the focus engine.
    @ViewBuilder
    private var licenseText: some View {
        #if os(tvOS)
        Text(license.text)
            .focusable(true)
        #else
        Text(license.text)
            .textSelection(.enabled)
        #endif
    }
}
