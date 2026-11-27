import Foundation
import Testing
@testable import BrewxPortCore

private func pkg(_ engine: EngineID, _ name: String) -> Package {
    Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name)
}

private struct Boom: Error {}

@Suite struct PackageCatalogTests {
    static let languages: [EngineID] = [.npm, .pipx, .uv, .cargo, .bun, .gem, .mint]

    @Test func defaultOrderArm() {
        #expect(PackageCatalog.defaultOrder(for: .arm64) == [.nanobrew, .homebrew, .macports, .mas] + Self.languages)
    }

    @Test func defaultOrderIntel() {
        #expect(PackageCatalog.defaultOrder(for: .x86_64) == [.macports, .homebrew, .nanobrew, .mas] + Self.languages)
    }

    @Test func defaultOrderPutsLanguagesAfterSystem() {
        for arch in [Arch.arm64, .x86_64] {
            let order = PackageCatalog.defaultOrder(for: arch)
            #expect(Set(order) == Set(EngineID.allCases))
            #expect(order.count == EngineID.allCases.count)
            #expect(order.prefix(4).allSatisfy { $0.group == .system })
            #expect(Array(order.dropFirst(4)) == Self.languages)
        }
    }

    @Test func mergeSortsLanguageEnginesAfterSystem() {
        let rg = Package(id: PackageRef(engine: .cargo, kind: .tool, name: "rg"), displayName: "rg")
        let outcomes = [
            EngineOutcome(engine: .cargo, result: .success([rg])),
            EngineOutcome(engine: .homebrew, result: .success([pkg(.homebrew, "rg")])),
            EngineOutcome(engine: .npm, result: .failure(EngineError(engine: .npm, message: "x"))),
            EngineOutcome(engine: .mas, result: .failure(EngineError(engine: .mas, message: "y"))),
        ]
        let merged = PackageCatalog.merge(outcomes, order: PackageCatalog.defaultOrder(for: .arm64))
        #expect(merged.packages.map(\.id.engine) == [.homebrew, .cargo])
        #expect(merged.errors.map(\.engine) == [.mas, .npm])
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

    /// A registry that's down (crates.io 503) or a manager that fails (pipx) marks only that engine as "couldn't
    /// check"; the other engines' updates are still listed.
    @Test func oneEngineFailureDoesNotHideOthers() async {
        func tool(_ engine: EngineID, _ name: String) -> Package {
            Package(id: PackageRef(engine: engine, kind: .tool, name: name), displayName: name)
        }
        let engines: [any Engine] = [
            StubEngine(id: .cargo, outdated: .failure(RegistryFetchError.status(503))),
            StubEngine(id: .npm, outdated: .success([tool(.npm, "typescript")])),
            StubEngine(id: .pipx, outdated: .failure(EngineError(engine: .pipx, message: "pipx couldn't check PyPI"))),
            StubEngine(id: .homebrew, outdated: .success([pkg(.homebrew, "wget")])),
            StubEngine(id: .mint, outdated: .success([tool(.mint, "SwiftLint")])),
        ]
        let r = await PackageCatalog(engines: engines, arch: .arm64).outdated()
        #expect(r.packages.map(\.id) == [
            PackageRef(engine: .mint, kind: .tool, name: "SwiftLint"),
            PackageRef(engine: .npm, kind: .tool, name: "typescript"),
            PackageRef(engine: .homebrew, kind: .formula, name: "wget"),
        ])
        #expect(r.errors.map(\.engine) == [.pipx, .cargo])
        #expect(r.errors.last?.message == String(describing: RegistryFetchError.status(503)))
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

    /// R6 and holds: an outdated check's packages that couldn't be checked and its held updates reach the outcome and
    /// the merged result; a held update nobody may pick joins the packages, marked, and one the engine still lists
    /// isn't listed twice.
    @Test func outdatedReportReachesTheMergedResult() async {
        func tool(_ name: String, _ installed: String = "1", _ latest: String = "2") -> Package {
            Package(id: PackageRef(engine: .cargo, kind: .tool, name: name), displayName: name,
                    installedVersion: installed, latestVersion: latest)
        }
        let rust = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        let ruby = UpdateHold(reason: "Came with Ruby", blocksAutomatic: true, blocksManual: false)
        let report = OutdatedReport(packages: [tool("bat"), tool("rake")],
                                    unchecked: UncheckedPackages(reasons: ["tokei": "crates.io didn't answer"]),
                                    held: [HeldUpdate(package: tool("ripgrep", "14.1.0", "16.0.0"), hold: rust),
                                           HeldUpdate(package: tool("rake"), hold: ruby)])
        let cargo = StubEngine(id: .cargo, report: report)
        let brew = StubEngine(id: .homebrew, outdated: .success([pkg(.homebrew, "jq")]))
        let catalog = PackageCatalog(engines: [cargo, brew], arch: .arm64)
        var outcomes: [EngineID: EngineOutcome] = [:]
        for await outcome in catalog.stream(.outdated) { outcomes[outcome.engine] = outcome }
        #expect(outcomes[.cargo]?.unchecked.names == ["tokei"])
        #expect(outcomes[.cargo]?.held.map(\.package.id.name) == ["ripgrep", "rake"])
        #expect(outcomes[.homebrew]?.unchecked == UncheckedPackages.none)
        #expect(outcomes[.homebrew]?.held == [])
        let merged = await catalog.outdated()
        #expect(merged.packages.map(\.id.name) == ["bat", "jq", "rake", "ripgrep"])
        #expect(merged.holds == [tool("ripgrep").id: rust, tool("rake").id: ruby])
        #expect(merged.unchecked == [.cargo: UncheckedPackages(reasons: ["tokei": "crates.io didn't answer"])])
        #expect(merged.errors.isEmpty)
        // The other queries ask for the plain lists: no report.
        _ = await catalog.installed()
        #expect(cargo.calls == ["checkOutdated", "checkOutdated", "listInstalled"])
    }

    /// An engine BrewxPort doesn't drive at its version (Bun before 1.4.5) isn't asked and isn't a failure: no
    /// outcome, no error, its status says why.
    @Test func unsupportedEngineIsQuiet() async {
        let path = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        let reason = "Bun 1.2.20 is too old for BrewxPort."
        let old = StubEngine(id: .bun, status: .unsupported(path: path, version: "1.2.20", reason: reason),
                             installed: .success([pkg(.bun, "x")]), outdated: .success([pkg(.bun, "x")]))
        let ok = StubEngine(id: .homebrew, outdated: .success([pkg(.homebrew, "y")]))
        let catalog = PackageCatalog(engines: [old, ok], arch: .arm64)
        var engines: [EngineID] = []
        for await outcome in catalog.stream(.outdated) { engines.append(outcome.engine) }
        #expect(engines == [.homebrew])
        #expect(await catalog.outdated().errors.isEmpty)
        #expect(await catalog.installed().errors.isEmpty)
        #expect(old.calls.isEmpty)
        #expect(PackageCatalog.message(for: .bun, status: .unsupported(path: path, version: "1.2.20", reason: reason))
                == reason)
        let rg = PackageRef(engine: .bun, kind: .tool, name: "x")
        await #expect(throws: EngineError(engine: .bun, message: reason)) { try await catalog.info(rg) }
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

    /// Details asked for before any list detect the engine first (a language engine knows its tool only after a
    /// detect), once; an engine a list already detected isn't detected again, and one that isn't there says so.
    @Test func infoDetectsAnEngineNoQueryHasDetected() async throws {
        let detects = Counter()
        let details = PackageDetails(ref: rgRef, summary: "grep, faster", latestVersion: "15.2.0")
        let brew = StubEngine(id: .homebrew, info: .success(details), onDetect: { detects.add() })
        let catalog = PackageCatalog(engines: [brew], arch: .arm64)
        #expect(try await catalog.info(rgRef) == details)
        #expect(detects.value == 1)
        #expect(try await catalog.info(rgRef) == details)
        #expect(detects.value == 1)

        let listed = Counter()
        let other = StubEngine(id: .homebrew, info: .success(details), onDetect: { listed.add() })
        let afterList = PackageCatalog(engines: [other], arch: .arm64)
        _ = await afterList.installed()
        #expect(try await afterList.info(rgRef) == details)
        #expect(listed.value == 1)

        let missing = StubEngine(id: .homebrew, status: .missing, info: .success(details))
        await #expect(throws: EngineError(engine: .homebrew, message: "Homebrew isn't installed")) {
            try await PackageCatalog(engines: [missing], arch: .arm64).info(rgRef)
        }
        #expect(missing.calls.isEmpty)
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

// MARK: taps (Plan 4 Task 3)

private func homebrewFixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/homebrew/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

extension PackageCatalogTests {
    @Test func catalogInstalledTapsEmptyWithoutHomebrew() async throws {
        let none = PackageCatalog(engines: [StubEngine(id: .macports)], arch: .arm64)
        #expect(try await none.installedTaps() == [])
        let runner = FakeRunner([:])
        let missing = PackageCatalog(engines: [HomebrewEngine(runner: runner, executable: nil)], arch: .arm64)
        #expect(try await missing.installedTaps() == [])
        #expect(runner.calls.isEmpty)
    }

    @Test func catalogInstalledTapsFromHomebrew() async throws {
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        let ok = { (s: String) in CommandResult(exitCode: 0, stdout: s, stderr: "") }
        let runner = FakeRunner([["--version"]: ok(try homebrewFixture("version.txt")),
                                 ["tap"]: ok(try homebrewFixture("tap.txt"))])
        let catalog = PackageCatalog(engines: [HomebrewEngine(runner: runner, executable: brew, arch: .arm64)],
                                     arch: .arm64)
        #expect(try await catalog.installedTaps() == ["felixkratz/formulae"])
    }

    @Test func catalogInstalledTapsThrowsWhenHomebrewUnusable() async {
        let broken = StubEngine(id: .homebrew, status: .unusable(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                                                  reason: "bad"))
        let catalog = PackageCatalog(engines: [broken], arch: .arm64)
        await #expect(throws: EngineError(engine: .homebrew, message: "Homebrew is installed but not working: bad")) {
            try await catalog.installedTaps()
        }
    }
}

/// Counts calls from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
