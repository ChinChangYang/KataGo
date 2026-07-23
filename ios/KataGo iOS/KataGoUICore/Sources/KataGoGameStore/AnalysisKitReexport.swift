// Re-export the Foundation-only analysis tier: PlayerColor moved there (the
// analysis parser's perspective flip needs it without dragging SwiftData into
// bridge-free link graphs), so this keeps every existing
// `import KataGoGameStore` consumer (widget, watch, Messages extension)
// seeing PlayerColor unchanged.
@_exported import KataGoAnalysisKit
