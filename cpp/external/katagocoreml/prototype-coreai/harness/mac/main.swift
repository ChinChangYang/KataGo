// PROTOTYPE (wayfinder #37), throwaway: the Mac command-line harness.
//   coreai-gate --mode <mode> --assets <workDir>/assets --out <dir> [options]   (see Harness.usage)
import Foundation

@main struct GateCLI {
    static func main() async {
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let code = await Harness.run(Array(CommandLine.arguments.dropFirst()),
                                     defaultAssets: here.appendingPathComponent("assets"),
                                     defaultOut: here.appendingPathComponent("results"))
        exit(code)
    }
}
