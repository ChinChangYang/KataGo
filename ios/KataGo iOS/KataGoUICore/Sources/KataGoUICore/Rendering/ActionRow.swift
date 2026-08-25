//
//  ActionRow.swift
//  KataGoUICore
//

import SwiftUI

/// An action row: secondary actions on the leading side, the default action
/// trailing — stacked instead when the buttons cannot fit side by side.
///
/// Layout only. Callers apply the button styles themselves, because the house
/// pair (`.glass` secondary + `.glassProminent` primary) does not exist on
/// visionOS/tvOS, and this package builds for all five platforms.
///
/// Measured on an iPhone 17 at Accessibility XXXL, not assumed. Two separate
/// findings drove this:
///
/// - The photo-import grid phase's four buttons (Back, Cancel, Retake,
///   Recognize) overflow the ~345pt lane at that text size with or without
///   glass — their labels alone want more than twice it. Adding `lineLimit(1)`
///   and `minimumScaleFactor(0.6)` was tried first and was not enough: the row
///   still rendered as "…", "C…", "R…", "R…".
/// - The preview phase's two buttons DID fit before the glass conversion
///   ("Cancel" rendered in full) and did not after, because each capsule adds
///   roughly 40pt of horizontal padding. So two buttons are not automatically
///   safe: any row converted to glass wants this, not just the crowded ones.
///
/// `ViewThatFits` measures the horizontal branch's ideal width — a `Spacer`
/// contributes zero, so it is just the sum of the buttons — and takes the
/// stacked branch only on genuine overflow, leaving every ordinary text size
/// laid out exactly as before. Scaling is kept as a floor beneath both branches
/// for narrow devices where even one capsule is tight.
public struct ActionRow<Secondary: View, Primary: View>: View {
    private let secondary: Secondary
    private let primary: Primary

    public init(@ViewBuilder secondary: () -> Secondary,
                @ViewBuilder primary: () -> Primary) {
        self.secondary = secondary()
        self.primary = primary()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                secondary
                Spacer()
                primary
            }
            // Primary first when stacked: it is the action the user most likely
            // wants, and a stacked row reads top-down.
            VStack(spacing: 10) {
                primary
                secondary
            }
            .frame(maxWidth: .infinity)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}
