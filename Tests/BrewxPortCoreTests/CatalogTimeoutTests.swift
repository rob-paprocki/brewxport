import Foundation
import Synchronization
import Testing
@testable import BrewxPortCore

private func pkg(_ engine: EngineID, _ name: String) -> Package {
    Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name)
}

@Suite struct CatalogTimeoutTests {
    /// The fast engine has to answer inside the same timeout as the slow one is cut off at, so the tests that have one
    /// give it 1.5 s rather than 0.3 s: a loaded CI runner has delayed in-process work by up to 1.65 s.
    static let raceTimeout: Duration = .milliseconds(1500)

    @Test func slowEngineTimesOutOthersReturn() async {
        // Cancellable, so a passing run doesn't wait for it.
        let slow = StubEngine(id: .mas, onSearch: { try? await Task.sleep(for: .seconds(60)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [slow, fast], arch: .arm64, queryTimeout: Self.raceTimeout)
        let start = ContinuousClock.now
        let r = await catalog.search("q")
        // Guards against waiting for the slow stub (60 s); the timeout plus CI's lag comes to about 3.7 s.
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(r.packages.map(\.id.name) == ["fd"])
        #expect(r.errors == [PackageCatalog.timeoutError(.mas, after: Self.raceTimeout)])
        #expect(r.errors.first?.message.hasPrefix("Mac App Store didn't answer within ") == true)
        #expect(r.errors.first?.message.hasSuffix(" seconds") == true)
    }

    @Test func hangingDetectDoesNotStallOthers() async {
        let hung = StubEngine(id: .mas, onDetect: { try? await Task.sleep(for: .seconds(60)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: Self.raceTimeout)
        let start = ContinuousClock.now
        let r = await catalog.search("q")
        // Guards against waiting for the hung detect (60 s); the timeout plus CI's lag comes to about 3.7 s.
        #expect(ContinuousClock.now - start < .seconds(15))
        #expect(r.packages.map(\.id.name) == ["fd"])
        #expect(r.errors.map(\.message) == ["Mac App Store is installed but not working: didn't answer within 1.5 seconds"])
    }

    @Test func hangingDetectDoesNotStallPresentEngines() async {
        let hung = StubEngine(id: .mas, onDetect: { try? await Task.sleep(for: .seconds(60)) })
        let fast = StubEngine(id: .homebrew)
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: Self.raceTimeout)
        let start = ContinuousClock.now
        let statuses = await catalog.presentEngines()
        // Guards against waiting for the hung detect (60 s); the timeout plus CI's lag comes to about 3.7 s.
        #expect(ContinuousClock.now - start < .seconds(15))
        if case .present = statuses[.homebrew] {} else { Issue.record("homebrew should be present") }
        if case .unusable(_, let reason) = statuses[.mas] {
            #expect(reason == "didn't answer within 1.5 seconds")
        } else { Issue.record("mas should be unusable") }
    }

    @Test func detectStatusMapsRunnerTimeoutToUnusable() async {
        struct TimedOutRunner: CommandRunning {
            func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
                #expect(options.timeout == BrewxPortTimeouts.engineQuery)
                throw CommandRunnerError.timedOut(options.timeout ?? .zero)
            }
            func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                        onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 { 0 }
        }
        let path = URL(fileURLWithPath: "/usr/bin/true")
        let status = await detectStatus(runner: TimedOutRunner(), executable: path, arguments: ["version"], parse: { $0 })
        #expect(status == .unusable(path: path, reason: "didn't answer within 60 seconds"))
    }

    @Test func defaultTimeoutText() {
        #expect(PackageCatalog.timeoutError(.mas, after: BrewxPortTimeouts.engineQuery).message
            == "Mac App Store didn't answer within 60 seconds")
    }

    @Test func messageForStatuses() {
        let url = URL(fileURLWithPath: "/usr/bin/true")
        #expect(PackageCatalog.message(for: .homebrew, status: .present(path: url, version: "1")) == nil)
        #expect(PackageCatalog.message(for: .homebrew, status: .missing) == "Homebrew isn't installed")
        #expect(PackageCatalog.message(for: .nanobrew, status: .missing) == "nanobrew isn't installed")
        #expect(PackageCatalog.message(for: .macports, status: .missing) == "MacPorts isn't installed")
        #expect(PackageCatalog.message(for: .mas, status: .unusable(path: url, reason: "exited 1"))
            == "Mac App Store is installed but not working: exited 1")
    }

    @Test func unusableMessageMatchesCatalogError() async {
        let status = EngineStatus.unusable(path: URL(fileURLWithPath: "/x"), reason: "boom")
        let r = await PackageCatalog(engines: [StubEngine(id: .homebrew, status: status)], arch: .arm64).installed()
        #expect(r.errors.map(\.message) == [PackageCatalog.message(for: .homebrew, status: status)])
    }

    @Test func hungDetectReportsEnginePath() async {
        let path = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let hung = StubEngine(id: .homebrew, onDetect: { try? await Task.sleep(for: .seconds(10)) },
                              executableURL: path)
        let catalog = PackageCatalog(engines: [hung], arch: .arm64, queryTimeout: .milliseconds(300))
        let statuses = await catalog.presentEngines()
        #expect(statuses[.homebrew] == .unusable(path: path, reason: "didn't answer within 0.3 seconds"))
    }

    @Test func detectTimeoutTextMatchesStatusMessage() async {
        let hung = StubEngine(id: .homebrew, onDetect: { try? await Task.sleep(for: .seconds(10)) },
                              executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
        let catalog = PackageCatalog(engines: [hung], arch: .arm64, queryTimeout: .milliseconds(300))
        let r = await catalog.search("x")
        #expect(r.errors.map(\.message) == ["Homebrew is installed but not working: didn't answer within 0.3 seconds"])
    }

    @Test func streamYieldsFastEngineBeforeHungOne() async {
        // Cancellable: dropping the iterator ends the stream, which cancels the query, so a passing run doesn't wait.
        let hung = StubEngine(id: .mas, onSearch: { try? await Task.sleep(for: .seconds(120)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: .seconds(60))
        let start = ContinuousClock.now
        var iterator = catalog.stream(.search("x")).makeAsyncIterator()
        let first = await iterator.next()
        // Guards against the first element waiting for the 60 s timeout; CI took up to 1.65 s here.
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(first?.engine == .homebrew)
        #expect((try? first?.result.get())?.map(\.id.name) == ["fd"])
    }

    @Test func cancellingStreamCancelsQueries() async {
        let sawCancel = Mutex(false)
        let hung = StubEngine(id: .mas, onSearch: {
            // Far longer than both polls below, so only the cancel can end it.
            do { try await Task.sleep(for: .seconds(120)) } catch { sawCancel.withLock { $0 = true } }
        })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        // A long timeout, so only the consumer going away can cancel the hung query.
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: .seconds(60))
        let gotFirst = Mutex(false)
        let consumer = Task {
            var iterator = catalog.stream(.search("x")).makeAsyncIterator()
            _ = await iterator.next()
            gotFirst.withLock { $0 = true }
            _ = await iterator.next()
        }
        // Each poll allows at least 5 s, like waitUntil: CI has taken 1.65 s to deliver a first element.
        var waited = 0
        while !gotFirst.withLock({ $0 }), waited < 500 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(gotFirst.withLock { $0 })
        consumer.cancel()
        waited = 0
        while !sawCancel.withLock({ $0 }), waited < 500 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(sawCancel.withLock { $0 })
        _ = await consumer.value
    }
}
