//
//  TVLoadingView.swift
//  KataGo Anytime TV
//
//  Engine-loading screen matching the iOS LoadingView design: a ticking
//  "Loading engine…" headline, a secondary Core ML compile-status line
//  (EngineLaunchStatus), and the spinning circular KataGo icon. tvOS
//  adaptations: the rotation repeats forever (a first-launch Core ML
//  compile outlasts iOS's single 20 s turn), there is no tap-to-spin
//  (nothing focusable on the remote), the secondary line is .title3 for
//  10-foot legibility, and Reduce Motion pins the icon.
//

import SwiftUI
import KataGoUICore

struct TVLoadingView: View {
    /// Headline base text; the view ticks trailing dots onto it.
    var caption: String

    @Environment(EngineLaunchStatus.self) private var launchStatus

    var body: some View {
        // Thin tvOS wrapper over the shared EngineLoadingView: a fixed 512 pt
        // icon and a .title3 secondary line for 10-foot legibility. The status
        // comes from the environment (injected by KataGoTVApp / the #Previews).
        EngineLoadingView(caption: caption,
                          secondaryFont: .title3,
                          icon: Image(.loadingIcon),
                          iconSizing: .fixed(512),
                          status: launchStatus)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Loading view") {
    TVLoadingView(caption: "Loading engine")
        .environment(EngineLaunchStatus())
}

#Preview("Loading view — compiling") {
    let status = EngineLaunchStatus()
    let _ = status.phase = .compilingMissFirstLaunch
    TVLoadingView(caption: "Loading engine")
        .environment(status)
}
#endif
