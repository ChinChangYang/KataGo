import Foundation

// Internal stderr writer for CoreMLCacheKit. Mirrors KataGoUICore's
// DebugUtils.printError but stays `internal` so it is not re-exported and
// cannot collide with KataGoUICore's public `printError` in consumers that
// import both modules.
func printError(_ item: Any) {
    // The legacy write(_:) raises an uncatchable NSException on a broken
    // stderr (EPIPE aborts the whole engine subprocess — seen in the wild
    // during CoreML handle loads). The throwing variant + try? never kills.
    try? FileHandle.standardError.write(contentsOf: Data("\(item)\n".utf8))
}
