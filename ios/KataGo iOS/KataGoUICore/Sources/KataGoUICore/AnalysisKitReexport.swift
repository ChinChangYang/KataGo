// Re-export the Foundation-only analysis tier so existing `import KataGoUICore`
// consumers (app targets, tests) keep seeing AnalysisLineParser, ParsedAnalysis,
// ParsedRootInfo, BoardPoint, Coordinate, AnalysisInfo, OwnershipUnit, and
// AnalysisCommand without per-file import changes. Bridge-free processes (the
// Safari extension) instead import KataGoAnalysisKit directly.
@_exported import KataGoAnalysisKit
