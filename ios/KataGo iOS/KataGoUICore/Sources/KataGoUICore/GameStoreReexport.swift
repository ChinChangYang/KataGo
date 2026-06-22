// Re-export the bridge-free model layer so existing `import KataGoUICore`
// consumers (app targets, AppIntents, tests) keep seeing GameRecord/Config and
// the shared store without per-file import changes. The widget extension
// instead imports KataGoGameStore directly.
@_exported import KataGoGameStore
