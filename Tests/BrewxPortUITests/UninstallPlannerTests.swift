import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// A small, hand-drawn graph for one package manager, turned into the `DependencyFacts` its gatherer would return.
private struct UninstallGraph {
    let engine: EngineID
    var kind: PackageKind = .formula
    var dependents: [String: Set<String>] = [:]
    var dependencies: [String: Set<String>] = [:]
    var packages: [String: Package] = [:]
    var dependenciesComplete = true

    init(_ engine: EngineID) {
        self.engine = engine
        if engine == .macports { kind = .port }
    }

    /// Installs `name`; `onRequest` is its install record (nil: it doesn't say).
    mutating func install(_ name: String, onRequest: Bool?, kind: PackageKind? = nil) {
        packages[name] = Package(id: PackageRef(engine: engine, kind: kind ?? self.kind, name: name), displayName: name,
                                 installedVersion: "1", installedOnRequest: onRequest)
        dependencies[name] = dependencies[name] ?? []
    }

    /// `user` depends on `library`, in both maps.
    mutating func uses(_ user: String, _ library: String) {
        dependents[library, default: []].insert(user)
        dependencies[user, default: []].insert(library)
    }

    func package(_ name: String) -> Package { packages[name]! }

    var facts: DependencyFacts {
        let known = packages.values.allSatisfy { $0.installedOnRequest != nil }
        let requested = known ? Set(packages.values.filter { $0.installedOnRequest == true }.map(\.id.name)) : nil
        return DependencyFacts(affected: Set(packages.keys), dependents: dependents, dependencies: dependencies,
                               requested: requested, installed: packages, dependenciesComplete: dependenciesComplete)
    }
}

/// Homebrew: wget (asked for) needs openssl@4 and libidn2; openssl@4 needs ca-certificates. Only wget was asked for.
private func wgetGraph(libidn2: Bool? = false) -> UninstallGraph {
    var g = UninstallGraph(.homebrew)
    g.install("wget", onRequest: true)
    g.install("openssl@4", onRequest: false)
    g.install("libidn2", onRequest: libidn2)
    g.install("ca-certificates", onRequest: false)
    g.uses("wget", "openssl@4")
    g.uses("wget", "libidn2")
    g.uses("openssl@4", "ca-certificates")
    return g
}

private func names(_ packages: [Package]) -> [String] { packages.map(\.id.name) }

private func plan(_ picks: [Package], _ graphs: UninstallGraph...) -> UninstallPlan {
    var facts: [EngineID: Result<DependencyFacts, DependencyGatherer.Failure>] = [:]
    for graph in graphs { facts[graph.engine] = .success(graph.facts) }
    return UninstallPlanner.plan(picks: picks, facts: facts)
}

@Suite struct UninstallPlannerTests {
    @Test func homebrewPickOffersLeftovers() throws {
        let g = wgetGraph()
        let made = plan([g.package("wget")], g)
        let section = try #require(made.sections.first)
        #expect(made.sections.count == 1)
        #expect(section.engine == .homebrew)
        #expect(names(section.picks) == ["wget"])
        #expect(section.blocked.isEmpty)
        #expect(names(section.leftovers) == ["ca-certificates", "libidn2", "openssl@4"])
        #expect(section.removeLeftovers)
        #expect(section.note == nil)
    }

    @Test func caskPickOffersLeftovers() throws {
        // The shape of the droid fixture: the cask needs ripgrep, which needs pcre2, neither asked for.
        var g = UninstallGraph(.homebrew)
        g.install("droid", onRequest: nil, kind: .cask)
        g.install("ripgrep", onRequest: false)
        g.install("pcre2", onRequest: false)
        g.uses("droid", "ripgrep")
        g.uses("ripgrep", "pcre2")
        let section = try #require(plan([g.package("droid")], g).sections.first)
        #expect(names(section.picks) == ["droid"])
        #expect(names(section.leftovers) == ["pcre2", "ripgrep"])
        #expect(section.note == nil)
    }

    @Test func requestedNeverLeftover() throws {
        let g = wgetGraph(libidn2: true)
        let section = try #require(plan([g.package("wget")], g).sections.first)
        #expect(names(section.leftovers) == ["ca-certificates", "openssl@4"])
    }

    @Test func unknownRequestedNeverLeftover() throws {
        // libidn2's record doesn't say, so the engine-wide requested set is unknown; the others still count.
        let g = wgetGraph(libidn2: nil)
        #expect(g.facts.requested == nil)
        let section = try #require(plan([g.package("wget")], g).sections.first)
        #expect(names(section.leftovers) == ["ca-certificates", "openssl@4"])
        #expect(section.note == nil)
    }

    @Test func pickStillNeededHasNoLeftoversFromIt() throws {
        // wget stays and needs openssl@4, so Homebrew refuses to remove it: nothing it needs is a leftover.
        let g = wgetGraph()
        let section = try #require(plan([g.package("openssl@4")], g).sections.first)
        #expect(names(section.picks) == ["openssl@4"])
        #expect(names(section.refused) == ["openssl@4"])
        #expect(section.blocked.isEmpty)
        #expect(section.leftovers.isEmpty)
        #expect(section.note == nil)
    }

    @Test func pickNeverAlsoLeftover() throws {
        let g = wgetGraph()
        let section = try #require(plan([g.package("wget"), g.package("libidn2")], g).sections.first)
        #expect(names(section.picks) == ["libidn2", "wget"])
        #expect(section.refused.isEmpty)
        #expect(names(section.leftovers) == ["ca-certificates", "openssl@4"])
    }

    @Test func nanobrewNoBox() throws {
        var g = UninstallGraph(.nanobrew)
        g.install("tool", onRequest: true)
        g.install("lib", onRequest: false)
        g.uses("tool", "lib")
        let section = try #require(plan([g.package("tool")], g).sections.first)
        #expect(section.engine == .nanobrew)
        #expect(names(section.picks) == ["tool"])
        #expect(section.blocked.isEmpty)
        #expect(section.leftovers.isEmpty)
        #expect(!section.removeLeftovers)
        #expect(section.note == nil)
    }

    @Test func nanobrewBlockedByDependent() throws {
        var g = UninstallGraph(.nanobrew)
        for name in ["lib", "tool", "other", "app", "free"] { g.install(name, onRequest: nil) }
        g.uses("tool", "lib")
        g.uses("other", "lib")
        g.uses("app", "tool")
        // tool is picked too, but app stays and needs it, so lib still has a user that stays.
        let made = plan([g.package("lib"), g.package("tool"), g.package("free")], g)
        let section = try #require(made.sections.first)
        #expect(names(section.picks) == ["free"])
        #expect(section.blocked == [
            BlockedPick(package: g.package("lib"), reason: "needed by other, tool."),
            BlockedPick(package: g.package("tool"), reason: "needed by app."),
        ])
        #expect(section.leftovers.isEmpty)
        #expect(section.note == nil)
    }

    @Test func nanobrewDependentAlsoPickedIsRemoved() throws {
        var g = UninstallGraph(.nanobrew)
        g.install("lib", onRequest: nil)
        g.install("tool", onRequest: nil)
        g.uses("tool", "lib")
        let section = try #require(plan([g.package("lib"), g.package("tool")], g).sections.first)
        #expect(names(section.picks) == ["lib", "tool"])
        #expect(section.blocked.isEmpty)
    }

    @Test func nanobrewCheckFailedBlocksPicks() throws {
        let lib = UninstallGraph.nanobrewFormula("lib")
        let tool = UninstallGraph.nanobrewFormula("tool")
        let timedOut = EngineError(engine: .nanobrew, message: "nanobrew didn't answer within 60 seconds")
        let inputs: [[EngineID: Result<DependencyFacts, DependencyGatherer.Failure>]] = [
            [.nanobrew: .failure(.failed(timedOut))],
            [.nanobrew: .failure(.tooMany)],
            [:],
        ]
        for input in inputs {
            let made = UninstallPlanner.plan(picks: [tool, lib], facts: input)
            let section = try #require(made.sections.first)
            #expect(section.picks.isEmpty)
            #expect(section.blocked == [
                BlockedPick(package: lib, reason: "BrewxPort couldn't check what needs it."),
                BlockedPick(package: tool, reason: "BrewxPort couldn't check what needs it."),
            ])
            #expect(section.leftovers.isEmpty)
            #expect(section.note == nil)
        }
    }

    @Test func homebrewCheckFailedNoBoxPicksStay() throws {
        var incomplete = wgetGraph()
        incomplete.dependenciesComplete = false
        let wget = incomplete.package("wget")
        let inputs: [[EngineID: Result<DependencyFacts, DependencyGatherer.Failure>]] = [
            [.homebrew: .failure(.failed(EngineError(engine: .homebrew, message: "brew uses failed")))],
            [.homebrew: .failure(.tooMany)],
            [.homebrew: .success(incomplete.facts)],
            [:],
        ]
        for input in inputs {
            let section = try #require(UninstallPlanner.plan(picks: [wget], facts: input).sections.first)
            #expect(names(section.picks) == ["wget"])
            #expect(section.blocked.isEmpty)
            #expect(section.leftovers.isEmpty)
            #expect(!section.removeLeftovers)
            #expect(section.note == "Couldn't work out leftovers for Homebrew.")
        }
    }

    @Test func macportsPortLeftovers() throws {
        var g = UninstallGraph(.macports)
        g.install("wget", onRequest: true)
        g.install("gettext", onRequest: false)
        g.install("libiconv", onRequest: false)
        g.install("curl", onRequest: true)
        g.uses("wget", "gettext")
        g.uses("gettext", "libiconv")
        g.uses("curl", "libiconv")
        let section = try #require(plan([g.package("wget")], g).sections.first)
        #expect(section.engine == .macports)
        #expect(names(section.picks) == ["wget"])
        #expect(names(section.leftovers) == ["gettext"])
        #expect(section.leftovers.allSatisfy { $0.id.kind == .port })
        #expect(section.removeLeftovers)

        var failed = g
        failed.dependenciesComplete = false
        let noted = try #require(plan([g.package("wget")], failed).sections.first)
        #expect(noted.note == "Couldn't work out leftovers for MacPorts.")
        #expect(names(noted.picks) == ["wget"])
        #expect(noted.leftovers.isEmpty)
    }

    @Test func masPicksNoBoxNoNote() throws {
        let app = Package(id: PackageRef(engine: .mas, kind: .app, name: "497799835"), displayName: "Xcode")
        let section = try #require(UninstallPlanner.plan(picks: [app], facts: [:]).sections.first)
        #expect(section.engine == .mas)
        #expect(section.picks == [app])
        #expect(section.blocked.isEmpty)
        #expect(section.leftovers.isEmpty)
        #expect(section.note == nil)
    }

    @Test func oneSectionPerManagerInManagerOrder() {
        let brew = wgetGraph()
        var port = UninstallGraph(.macports)
        port.install("wget", onRequest: true)
        var nb = UninstallGraph(.nanobrew)
        nb.install("tool", onRequest: nil)
        let made = plan([port.package("wget"), nb.package("tool"), brew.package("wget"), brew.package("wget")],
                        brew, port, nb)
        #expect(made.sections.map(\.engine) == [.homebrew, .nanobrew, .macports])
        #expect(made.sections.map { names($0.picks) } == [["wget"], ["tool"], ["wget"]])
    }

    @Test func noPicksNoSections() {
        #expect(UninstallPlanner.plan(picks: [], facts: [:]).sections.isEmpty)
    }
}

private extension UninstallGraph {
    static func nanobrewFormula(_ name: String) -> Package {
        Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: name), displayName: name, installedVersion: "1")
    }
}
