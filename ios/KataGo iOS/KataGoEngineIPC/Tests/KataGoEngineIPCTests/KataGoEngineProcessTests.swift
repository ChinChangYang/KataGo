import Testing
import Foundation
@testable import KataGoEngineIPC

/// Hermetic tests for the subprocess manager. Each test spawns a tiny perl
/// "stub engine" (written to a temp file) so the manager's spawn / duplex
/// line-I/O / lifecycle behavior is exercised with no real engine.
@Suite struct KataGoEngineProcessTests {

    /// Write an executable perl script (autoflushed stdout) to a temp file.
    static func makeStub(_ perlBody: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("katago-ipc-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stub-\(UUID().uuidString).pl")
        let script = "#!/usr/bin/perl\n$| = 1;\n" + perlBody + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A flushing line echo: prints back each line it receives.
    static func echoStub() throws -> URL {
        try makeStub(#"while (my $l = <STDIN>) { print $l; }"#)
    }

    @Test func sendThenReceiveRoundTripsOneLine() throws {
        let engine = KataGoEngineProcess(executableURL: try Self.echoStub(), arguments: [])
        try engine.start()
        engine.sendCommand("hello world")
        #expect(engine.getMessageLine() == "hello world")
        engine.terminate()
    }

    @Test func deliversMultipleLinesInOrder() throws {
        let engine = KataGoEngineProcess(executableURL: try Self.echoStub(), arguments: [])
        try engine.start()
        for cmd in ["one", "two", "three"] { engine.sendCommand(cmd) }
        #expect(engine.getMessageLine() == "one")
        #expect(engine.getMessageLine() == "two")
        #expect(engine.getMessageLine() == "three")
        engine.terminate()
    }

    @Test func splitsAMultiLineBurstWrittenAtOnce() throws {
        // Stub emits a 3-line burst in a single write (like showboard output).
        let stub = try Self.makeStub(#"print "= L1\nL2\nL3\n";"#)
        let engine = KataGoEngineProcess(executableURL: stub, arguments: [])
        try engine.start()
        #expect(engine.getMessageLine() == "= L1")
        #expect(engine.getMessageLine() == "L2")
        #expect(engine.getMessageLine() == "L3")
        engine.terminate()
    }

    @Test func returnsEmptyStringAfterChildExitsAndBufferDrained() throws {
        // Stub prints one line then exits on its own (models an engine quitting/crashing).
        let stub = try Self.makeStub(#"print "ready\n"; exit 0;"#)
        let engine = KataGoEngineProcess(executableURL: stub, arguments: [])
        try engine.start()
        #expect(engine.getMessageLine() == "ready")
        // Subsequent reads see EOF and return "" promptly (do not block forever).
        #expect(engine.getMessageLine() == "")
        #expect(engine.getMessageLine() == "")
    }

    @Test func terminateStopsAStillRunningChild() throws {
        // Echo stub blocks reading stdin forever until we stop it.
        let engine = KataGoEngineProcess(executableURL: try Self.echoStub(), arguments: [])
        try engine.start()
        #expect(engine.isRunning == true)
        engine.terminate()
        #expect(engine.isRunning == false)
    }

    @Test func reportsEOFOnlyAfterChildExitAndDrain() throws {
        let stub = try Self.makeStub(#"print "x\n"; exit 0;"#)
        let engine = KataGoEngineProcess(executableURL: stub, arguments: [])
        try engine.start()
        #expect(engine.getMessageLine() == "x")
        #expect(engine.getMessageLine() == "")        // EOF, drained
        #expect(engine.hasReachedEOF == true)
    }

    @Test func blankLineIsNotEOFWhileRunning() throws {
        // A legitimate empty output line must NOT be mistaken for EOF.
        let engine = KataGoEngineProcess(executableURL: try Self.echoStub(), arguments: [])
        try engine.start()
        engine.sendCommand("")                          // echoed back as a blank line
        #expect(engine.getMessageLine() == "")
        #expect(engine.hasReachedEOF == false)
        engine.terminate()
    }

    @Test func sendCommandAfterChildExitedIsSafeNoOp() throws {
        // Regression: writing to an exited child's stdin must NOT raise SIGPIPE
        // (which would kill the whole process) — it must be a swallowed no-op.
        let stub = try Self.makeStub(#"print "bye\n"; exit 0;"#)
        let engine = KataGoEngineProcess(executableURL: stub, arguments: [])
        try engine.start()
        #expect(engine.getMessageLine() == "bye")
        #expect(engine.getMessageLine() == "")          // EOF (child exited)
        engine.sendCommand("this should be ignored, not crash")
        #expect(engine.isRunning == false)
    }

    @Test func terminateIsIdempotent() throws {
        let engine = KataGoEngineProcess(executableURL: try Self.echoStub(), arguments: [])
        try engine.start()
        engine.terminate()
        engine.terminate()   // second call is a safe no-op
        #expect(engine.isRunning == false)
    }

    @Test func concurrentInstancesAreIndependent() throws {
        // Each stub tags output with its own $ENV{TAG}; proves separate stdio
        // per child (the basis for multi-window). 4 engines, interleaved I/O.
        let tagStub = try Self.makeStub(
            #"my $t=$ENV{TAG}; while (my $l=<STDIN>) { chomp $l; print "$t:$l\n"; }"#)
        let tags = ["A", "B", "C", "D"]
        let engines = try tags.map { tag -> KataGoEngineProcess in
            let e = KataGoEngineProcess(executableURL: tagStub, arguments: [], environment: ["TAG": tag])
            try e.start()
            return e
        }
        // Send to all first (interleaved), then read from all.
        for e in engines { e.sendCommand("ping") }
        for (i, e) in engines.enumerated() {
            #expect(e.getMessageLine() == "\(tags[i]):ping")
        }
        // Second round, reverse order, still independent.
        for e in engines.reversed() { e.sendCommand("pong") }
        for (i, e) in engines.enumerated() {
            #expect(e.getMessageLine() == "\(tags[i]):pong")
        }
        for e in engines { e.terminate() }
    }
}
