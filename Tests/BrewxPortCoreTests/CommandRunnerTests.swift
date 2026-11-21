import Testing
import Foundation
@testable import BrewxPortCore

@Suite struct CommandRunnerTests {
    let runner = ProcessRunner()

    @Test func runsEchoAndCapturesStdout() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"])
        #expect(r.stdout == "hi\n")
        #expect(r.exitCode == 0)
    }

    @Test func capturesNonZeroExit() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/usr/bin/false"), [])
        #expect(r.exitCode == 1)
    }

    @Test func separatesStderr() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo e 1>&2"])
        #expect(r.stderr == "e\n")
        #expect(r.stdout == "")
    }

    @Test func capturesLargeStdoutWithoutDeadlock() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                     ["-c", "head -c 1048576 /dev/zero | tr '\\0' a"])
        #expect(r.stdout.utf8.count == 1_048_576)
        #expect(r.exitCode == 0)
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/binary"), [])
        }
    }

    @Test func baseEnvironmentHasNoUserPATHButKnownPrefixes() {
        let env = ProcessRunner.baseEnvironment
        let path = env["PATH"] ?? ""
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"] {
            #expect(path.split(separator: ":").contains(Substring(p)))
        }
        #expect(env["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        // Without it, NO_AUTO_UPDATE also freezes Homebrew's package data, so Updates compares against whatever was
        // downloaded the last time brew ran in Terminal (Homebrew 7 api.rb; checked in a VM 2026-11-21).
        #expect(env["HOMEBREW_FORCE_API_AUTO_UPDATE"] == "1")
        #expect(env["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(env["NONINTERACTIVE"] == "1")
    }

    @Test func fakeRunnerRecordsAndDefaults() async throws {
        let ok = CommandResult(exitCode: 0, stdout: "x", stderr: "")
        let fake = FakeRunner([["a", "b"]: ok])
        let exe = URL(fileURLWithPath: "/x")
        #expect(try await fake.run(exe, ["a", "b"]) == ok)
        #expect(try await fake.run(exe, ["z"]).exitCode == 127)
        #expect(fake.calls == [["a", "b"], ["z"]])
    }

    @Test func cancelTerminatesChild() async throws {
        let marker = "sleep 31"
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["31"])
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(6))
        try await Task.sleep(for: .milliseconds(200))
        let pg = Process()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-f", marker]
        pg.standardOutput = FileHandle.nullDevice
        try pg.run()
        pg.waitUntilExit()
        #expect(pg.terminationStatus == 1)  // 1 = no match
    }

    @Test func cancelBeforeLaunchNeverLeavesChild() async throws {
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["32"])
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancelWithDescendantHoldingPipeReturns() async throws {
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 33 & wait"])
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount("sleep 33") == 0)
    }

    @Test func timeoutWithDescendantHoldingPipeReturns() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(300))) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 34 & wait"],
                                     options: RunOptions(timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - start < .seconds(8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount("sleep 34") == 0)
    }

    @Test func cancelAfterChildExitedWithDescendantHoldingPipe() async throws {
        let task = Task {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 35 &"])
        }
        try await Task.sleep(for: .milliseconds(400))  // sh has exited; sleep holds the pipes
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount("sleep 35") == 0)
    }

    @Test func timeoutAfterChildExitedWithDescendantHoldingPipe() async throws {
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(600))) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 36 &"],
                                     options: RunOptions(timeout: .milliseconds(600)))
        }
        #expect(ContinuousClock.now - start < .seconds(8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount("sleep 36") == 0)
    }

    @Test func timeoutTerminates() async {
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(500))) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"],
                                     options: RunOptions(timeout: .milliseconds(500)))
        }
    }

    @Test func stoppedChildEndsOnTimeoutWithoutWaitingForKill() async {
        // The shell stops itself, as an interactive shell on a terminal it doesn't own is stopped by SIGTTIN. SIGTERM
        // alone stays pending on a stopped process; the SIGCONT after it lets the trap run at once. (Without SIGCONT
        // this took over 2 s.)
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(300))) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                     ["-c", "trap 'exit 7' TERM; kill -STOP $$; sleep 38"],
                                     options: RunOptions(timeout: .milliseconds(300)))
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func newSessionHasNoControllingTerminal() async throws {
        // Opening /dev/tty needs a controlling terminal. In a new session there is none, even when the test itself
        // runs on a terminal (Tests/scripts/test-login-shell.sh runs this under `script`).
        let options = RunOptions(timeout: .seconds(5), newSession: true)
        let r = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", ": </dev/tty"], options: options)
        #expect(r.exitCode != 0)
        #expect(!r.stderr.isEmpty)
    }

    @Test func newSessionStillKillsDescendantsOnTimeout() async throws {
        // A session leader is also its own process group leader, so killpg(pid) reaches the background sleep.
        let start = ContinuousClock.now
        await #expect(throws: CommandRunnerError.timedOut(.milliseconds(300))) {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 39 & wait"],
                                     options: RunOptions(timeout: .milliseconds(300), newSession: true))
        }
        #expect(ContinuousClock.now - start < .seconds(8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(pgrepCount("sleep 39") == 0)
    }

    @Test func newSessionRunsNormally() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"], options: RunOptions(newSession: true))
        #expect(r.stdout == "hi\n")
        #expect(r.exitCode == 0)
    }

    @Test func signalExitIs128PlusN() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "kill -TERM $$"])
        #expect(r.exitCode == 143)
    }

    @Test func streamDeliversLinesInOrder() async throws {
        let events = EventBox()
        let code = try await runner.stream(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo a; echo b 1>&2; echo c"],
            options: RunOptions(), onOutput: { events.add($0) })
        #expect(code == 0)
        let all = events.all
        #expect(all.compactMap { if case .stdout(let s) = $0 { s } else { nil } } == ["a", "c"])
        #expect(all.compactMap { if case .stderr(let s) = $0 { s } else { nil } } == ["b"])
    }

    @Test func streamFlushesFinalUnterminatedLine() async throws {
        let events = EventBox()
        _ = try await runner.stream(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'x\\ny'"],
            options: RunOptions(), onOutput: { events.add($0) })
        #expect(events.all == [.stdout("x"), .stdout("y")])
    }

    @Test func environmentOptionReplacesBase() async throws {
        let r = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/env"), [],
            options: RunOptions(environment: ["BREWXPORT_X": "1"]))
        #expect(r.stdout == "BREWXPORT_X=1\n")
    }

    @Test func workingDirectoryOptionSetsChildCwd() async throws {
        let r = try await runner.run(
            URL(fileURLWithPath: "/bin/pwd"), [],
            options: RunOptions(workingDirectory: "/"))
        #expect(r.stdout == "/\n")
    }

    @Test func missingWorkingDirectoryIsLaunchFailed() async {
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/pwd"), [],
                                     options: RunOptions(workingDirectory: "/nonexistent/brewxport-cwd"))
            Issue.record("expected throw")
        } catch let e as CommandRunnerError {
            guard case .launchFailed = e else { Issue.record("wrong case \(e)"); return }
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func missingExecutableIsLaunchFailed() async {
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/nonexistent/binary"), [])
            Issue.record("expected throw")
        } catch let e as CommandRunnerError {
            guard case .launchFailed = e else { Issue.record("wrong case \(e)"); return }
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func pipeReadErrorIsReported() async {
        let reader = PipeReader(fd: -1, onData: { _ in }, onFailure: { _ in })
        do {
            try await reader.finish()
            Issue.record("expected throw")
        } catch let e as CommandRunnerError {
            guard case .readFailed = e else { Issue.record("wrong case \(e)"); return }
        } catch { Issue.record("wrong error \(error)") }
    }
}

/// Number of processes whose command line matches `pattern` (0 when pgrep finds none).
func pgrepCount(_ pattern: String) -> Int {
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-f", pattern]
    let out = Pipe()
    pg.standardOutput = out
    try? pg.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    pg.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OutputEvent] = []
    func add(_ e: OutputEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [OutputEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
