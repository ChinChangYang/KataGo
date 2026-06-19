import Foundation

// Internal stderr writer for CoreMLCacheKit. Mirrors KataGoUICore's
// DebugUtils.printError but stays `internal` so it is not re-exported and
// cannot collide with KataGoUICore's public `printError` in consumers that
// import both modules.
func printError(_ item: Any) {
    FileHandle.standardError.write(Data("\(item)\n".utf8))
}
