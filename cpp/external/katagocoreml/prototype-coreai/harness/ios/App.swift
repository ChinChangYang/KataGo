// PROTOTYPE (wayfinder #37), throwaway: the iPad harness app.
//
// Launched by stage1.sh through `devicectl device process launch --console ... -- --mode <mode> ... --exit`, it runs
// the mode at once, streams the same Markdown to the console, writes JSON to Documents/results, and exits. Launched by
// hand, it offers the modes as buttons. The screen stays awake while it runs.
import SwiftUI
import UIKit

@main struct CoreAIGateApp: App {
    @State private var runner = Runner()
    var body: some Scene {
        WindowGroup {
            ContentView(runner: runner)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
                    if args.contains("--mode") { runner.start(args) }
                }
        }
    }
}

@MainActor @Observable final class Runner {
    var lines: [String] = []
    var running = false

    func start(_ args: [String]) {
        guard !running else { return }
        running = true
        lines = []
        logSink = { s in Task { @MainActor in self.lines.append(contentsOf: s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) } }
        let assets = Bundle.main.resourceURL!.appendingPathComponent("assets")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results")
        let exitWhenDone = args.contains("--exit")
        Task.detached {
            let code = await Harness.run(args, defaultAssets: assets, defaultOut: docs)
            if exitWhenDone { exit(code) }
            await MainActor.run { self.running = false }
        }
    }
}

struct ContentView: View {
    let runner: Runner
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Core AI gate, stage 1").font(.headline)
            HStack {
                ForEach(["info", "idle", "parity", "mish", "residency"], id: \.self) { m in
                    Button(m) { runner.start(["--mode", m]) }.buttonStyle(.bordered).disabled(runner.running)
                }
                Button("speed (smoke)") { runner.start(["--mode", "speed", "--samples", "100", "--reps", "1", "--allow-busy"]) }
                    .buttonStyle(.bordered).disabled(runner.running)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(runner.lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).id(i)
                        }
                    }
                }
                .onChange(of: runner.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .padding()
    }
}
