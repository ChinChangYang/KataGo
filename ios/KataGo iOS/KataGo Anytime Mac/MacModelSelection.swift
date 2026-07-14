import Foundation
import KataGoUICore

/// The Mac model-selection store is the shared `ModelSelectionStore`
/// (KataGoUICore/Services), promoted from this target when the Vision app
/// gained model switching — same `ModelRunnerView.*` UserDefaults keys,
/// same semantics. The alias keeps the Mac call sites reading naturally.
typealias MacModelSelection = ModelSelectionStore
