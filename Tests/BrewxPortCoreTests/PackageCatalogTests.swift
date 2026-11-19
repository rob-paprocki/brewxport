import Foundation
import Testing
@testable import BrewxPortCore

private func pkg(_ engine: EngineID, _ name: String) -> Package {
    Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name)
}

private struct Boom: Error {}

@Suite struct PackageCatalogTests {
    @Test func defaultOrderArm() {
        #expect(PackageCatalog.defaultOrder(for: .arm64) == [.nanobrew, .homebrew, .macports, .mas])
    }

    @Test func defaultOrderIntel() {
        #expect(PackageCatalog.defaultOrder(for: .x86_64) == [.macports, .homebrew, .nanobrew, .mas])
    }

    @Test func mergeKeepsSameNameFromDifferentEngines() async {
        let engines: [any Engine] = [
            StubEngine(id: .macports, search: .success([pkg(.macports, "ripgrep")])),
            StubEngine(id: .nanobrew, search: .success([pkg(.nanobrew, "ripgrep")])),
        ]
        let arm = await PackageCatalog(engines: engines, arch: .arm64).search("rg")
        #expect(arm.packages.map(\.id.engine) == [.nanobrew, .macports])
        let intel = await PackageCatalog(engines: engines, arch: .x86_64).search("rg")
        #expect(intel.packages.map(\.id.engine) == [.macports, .nanobrew])
    }

    @Test func sortsByNameCaseInsensitively() async {
        let e = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "zlib"), pkg(.homebrew, "Bat"), pkg(.homebrew, "awk")]))
        let r = await PackageCatalog(engines: [e], arch: .arm64).search("x")
        #expect(r.packages.map(\.displayName) == ["awk", "Bat", "zlib"])
    }

    @Test func searchSurvivesOneEngineFailing() async {
        let engines: [any Engine] = [
            StubEngine(id: .homebrew, search: .failure(EngineError(engine: .homebrew, message: "bad"))),
            StubEngine(id: .nanobrew, search: .success([pkg(.nanobrew, "fd")])),
        ]
        let r = await PackageCatalog(engines: engines, arch: .arm64).search("fd")
        #expect(r.packages.count == 1)
        #expect(r.errors == [EngineError(engine: .homebrew, message: "bad")])
    }

    @Test func foreignErrorsAreWrapped() async {
        let e = StubEngine(id: .mas, installed: .failure(Boom()))
        let r = await PackageCatalog(engines: [e], arch: .arm64).installed()
        #expect(r.errors.count == 1)
        #expect(r.errors[0].engine == .mas)
        #expect(r.errors[0].message == String(describing: Boom()))
    }

    @Test func errorsAreSortedByEngineOrder() async {
        let engines: [any Engine] = [
            StubEngine(id: .mas, outdated: .failure(Boom())),
            StubEngine(id: .homebrew, outdated: .failure(Boom())),
            StubEngine(id: .nanobrew, outdated: .failure(Boom())),
        ]
        let r = await PackageCatalog(engines: engines, arch: .arm64).outdated()
        #expect(r.errors.map(\.engine) == [.nanobrew, .homebrew, .mas])
    }

    @Test func missingEnginesSkipped() async {
        let missing = StubEngine(id: .macports, status: .missing, search: .success([pkg(.macports, "x")]))
        let ok = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "y")]))
        let catalog = PackageCatalog(engines: [missing, ok], arch: .arm64)
        let r = await catalog.search("q")
        #expect(missing.calls.isEmpty)
        #expect(r.packages.map(\.displayName) == ["y"])
        #expect(r.errors.isEmpty)
        let present = await catalog.presentEngines()
        #expect(present[.macports] == .missing)
        #expect(present.count == 2)
    }

    @Test func unusableEngineReportsError() async {
        let path = URL(fileURLWithPath: "/opt/local/bin/port")
        let broken = StubEngine(id: .macports, status: .unusable(path: path, reason: "`port version` exited 1"),
                                search: .success([pkg(.macports, "x")]), installed: .success([pkg(.macports, "x")]),
                                outdated: .success([pkg(.macports, "x")]))
        let ok = StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "y")]))
        let catalog = PackageCatalog(engines: [broken, ok], arch: .arm64)
        let expected = [EngineError(engine: .macports, message: "MacPorts is installed but not working: `port version` exited 1")]
        let found = await catalog.search("q")
        #expect(found.packages.map(\.displayName) == ["y"])
        #expect(found.errors == expected)
        #expect(await catalog.installed().errors == expected)
        #expect(await catalog.outdated().errors == expected)
        #expect(broken.calls.isEmpty)
        #expect(await catalog.presentEngines()[.macports] == .unusable(path: path, reason: "`port version` exited 1"))
    }

    @Test(.timeLimit(.minutes(1))) func runsEnginesConcurrently() async {
        let barrier = TwoPartyBarrier()
        let wait: @Sendable () async -> Void = { await barrier.arriveAndWait() }
        let engines: [any Engine] = [
            StubEngine(id: .homebrew, search: .success([pkg(.homebrew, "a")]), onSearch: wait),
            StubEngine(id: .nanobrew, search: .success([pkg(.nanobrew, "b")]), onSearch: wait),
        ]
        let r = await PackageCatalog(engines: engines, arch: .arm64).search("q")
        #expect(r.packages.count == 2)
    }

    @Test func sameNameTiesBreakByKind() async {
        // The cask comes first from the engine, so a stable sort alone would keep it first.
        let cask = Package(id: PackageRef(engine: .homebrew, kind: .cask, name: "docker"), displayName: "docker")
        let formula = Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "docker"), displayName: "docker")
        let engine = StubEngine(id: .homebrew, search: .success([cask, formula]))
        let r = await PackageCatalog(engines: [engine], arch: .arm64).search("docker")
        #expect(r.packages.map(\.id.kind) == [.formula, .cask])
    }

    @Test func mergedQueriesMatchStream() async {
        let engines: [any Engine] = [
            StubEngine(id: .macports, search: .success([pkg(.macports, "ripgrep"), pkg(.macports, "fd")])),
            StubEngine(id: .nanobrew, search: .success([pkg(.nanobrew, "ripgrep")])),
            StubEngine(id: .mas, search: .failure(EngineError(engine: .mas, message: "boom"))),
            StubEngine(id: .homebrew, status: .missing),
        ]
        let catalog = PackageCatalog(engines: engines, arch: .arm64)
        let searched = await catalog.search("x")
        var outcomes: [EngineOutcome] = []
        for await outcome in catalog.stream(.search("x")) { outcomes.append(outcome) }
        #expect(outcomes.count == 3)  // the missing engine yields nothing
        let merged = PackageCatalog.merge(outcomes, order: PackageCatalog.defaultOrder(for: .arm64))
        #expect(merged.packages == searched.packages)
        #expect(merged.errors == searched.errors)
        #expect(searched.packages.map(\.id.engine) == [.macports, .nanobrew, .macports])
        #expect(searched.errors.map(\.message) == ["boom"])
    }
}

// MARK: info

@Suite struct PackageCatalogInfoTests {
    private let rgRef = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")

    @Test func infoRoutesToTheRefsEngine() async throws {
        let details = PackageDetails(ref: rgRef, summary: "grep, faster", latestVersion: "15.2.0")
        let brew = StubEngine(id: .homebrew, info: .success(details))
        let other = StubEngine(id: .mas)
        let catalog = PackageCatalog(engines: [other, brew], arch: .arm64)
        #expect(try await catalog.info(rgRef) == details)
        #expect(brew.calls == ["info"])
        #expect(other.calls.isEmpty)
    }

    @Test func infoTimesOut() async {
        let slow = StubEngine(id: .homebrew, onInfo: { try? await Task.sleep(for: .seconds(10)) })
        let catalog = PackageCatalog(engines: [slow], arch: .arm64, queryTimeout: .milliseconds(300))
        let start = ContinuousClock.now
        do {
            _ = try await catalog.info(rgRef)
            Issue.record("expected a timeout")
        } catch let error as EngineError {
            #expect(error == EngineError(engine: .homebrew, message: "Homebrew didn't answer within 0.3 seconds"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func infoForUnknownEngineThrows() async {
        let catalog = PackageCatalog(engines: [StubEngine(id: .mas)], arch: .arm64)
        await #expect(throws: EngineError.self) { try await catalog.info(rgRef) }
    }

    @Test func infoPassesEngineErrorsThrough() async {
        let failing = StubEngine(id: .homebrew, info: .failure(EngineError(engine: .homebrew, message: "kaput")))
        let catalog = PackageCatalog(engines: [failing], arch: .arm64)
        do {
            _ = try await catalog.info(rgRef)
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error == EngineError(engine: .homebrew, message: "kaput"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func infoWrapsForeignErrorsAsEngineError() async {
        struct Odd: Error {}
        let failing = StubEngine(id: .homebrew, info: .failure(Odd()))
        let catalog = PackageCatalog(engines: [failing], arch: .arm64)
        await #expect(throws: EngineError.self) { try await catalog.info(rgRef) }
    }
}
