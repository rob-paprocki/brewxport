import Foundation
import Synchronization
import Testing
@testable import BrewxPortCore

private func pkg(_ engine: EngineID, _ name: String) -> Package {
    Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name)
}

@Suite struct CatalogTimeoutTests {
    @Test func slowEngineTimesOutOthersReturn() async {
        let slow = StubEngine(id: .mas, onSearch: { try? await Task.sleep(for: .seconds(10)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [slow, fast], arch: .arm64, queryTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        let r = await catalog.search("q")
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(r.packages.map(\.id.name) == ["fd"])
        #expect(r.errors == [PackageCatalog.timeoutError(.mas, after: .milliseconds(300))])
        #expect(r.errors.first?.message.hasPrefix("Mac App Store didn't answer within ") == true)
        #expect(r.errors.first?.message.hasSuffix(" seconds") == true)
    }

    @Test func hangingDetectDoesNotStallOthers() async {
        let hung = StubEngine(id: .mas, onDetect: { try? await Task.sleep(for: .seconds(10)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        let r = await catalog.search("q")
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(r.packages.map(\.id.name) == ["fd"])
        #expect(r.errors.map(\.message) == ["Mac App Store is installed but not working: didn't answer within 0.3 seconds"])
    }

    @Test func hangingDetectDoesNotStallPresentEngines() async {
        let hung = StubEngine(id: .mas, onDetect: { try? await Task.sleep(for: .seconds(10)) })
        let fast = StubEngine(id: .homebrew)
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        let statuses = await catalog.presentEngines()
        #expect(ContinuousClock.now - start < .seconds(5))
        if case .present = statuses[.homebrew] {} else { Issue.record("homebrew should be present") }
        if case .unusable(_, let reason) = statuses[.mas] {
            #expect(reason == "didn't answer within 0.3 seconds")
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
        let hung = StubEngine(id: .mas, onSearch: { try? await Task.sleep(for: .seconds(10)) })
        let fast = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "fd")]))
        let catalog = PackageCatalog(engines: [hung, fast], arch: .arm64, queryTimeout: .seconds(5))
        let start = ContinuousClock.now
        var iterator = catalog.stream(.search("x")).makeAsyncIterator()
        let first = await iterator.next()
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(first?.engine == .homebrew)
        #expect((try? first?.result.get())?.map(\.id.name) == ["fd"])
    }

    @Test func cancellingStreamCancelsQueries() async {
        let sawCancel = Mutex(false)
        let hung = StubEngine(id: .mas, onSearch: {
            do { try await Task.sleep(for: .seconds(10)) } catch { sawCancel.withLock { $0 = true } }
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
        var waited = 0
        while !gotFirst.withLock({ $0 }), waited < 200 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(gotFirst.withLock { $0 })
        consumer.cancel()
        waited = 0
        while !sawCancel.withLock({ $0 }), waited < 200 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(sawCancel.withLock { $0 })
        _ = await consumer.value
    }
}
