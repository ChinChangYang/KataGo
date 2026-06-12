import SwiftUI

/// Lists every third-party component shipped in the app, with its license.
struct AcknowledgmentsView: View {
    var body: some View {
        List(ThirdPartyLicense.all) { license in
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
struct LicenseDetailView: View {
    let license: ThirdPartyLicense

    var body: some View {
        ScrollView {
            Text(license.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(license.name)
    }
}
