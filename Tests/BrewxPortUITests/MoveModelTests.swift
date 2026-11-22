import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// A real engine's commands with canned dependents and installed lists, so the move model's gathering and the run
/// verifier can be driven without scripting a command runner.
class MoveFakeEngine: Engine, DependentsListing, @unchecked Sendable {
    private let wrapped: any Engine
    fileprivate let lock = NSLock()
    private var _dependents: [String: Set<String>] = [:]
    private var _failDependents: Set<String> = []
    private var _installed: Result<[Package], EngineError> = .success([])
    private var _dependentsCalls: [String] = []
    private var _gate: Gate?
    /// When set, every dependents call waits for it.
    var gate: Gate? {
        get { lock.withLock { _gate } }
        set { lock.withLock { _gate = newValue } }
    }

    init(wrapping engine: any Engine) { wrapped = engine }

    func setDependents(_ name: String, _ names: Set<String>) { lock.withLock { _dependents[name] = names } }
    func failDependents(_ name: String) { lock.withLock { _ = _failDependents.insert(name) } }
    var installed: Result<[Package], EngineError> {
        get { lock.withLock { _installed } }
        set { lock.withLock { _installed = newValue } }
    }
    var dependentsCalls: [String] { lock.withLock { _dependentsCalls } }

    var id: EngineID { wrapped.id }
    var capabilities: EngineCapabilities { wrapped.capabilities }
    var executableURL: URL? { wrapped.executableURL }
    var runArch: Arch { wrapped.runArch }
    func detect() async -> EngineStatus { .present(path: wrapped.executableURL!, version: "1") }
    func search(_ query: String) async throws -> [Package] { [] }
    func listInstalled() async throws -> [Package] { try installed.get() }
    func listOutdated() async throws -> [Package] { [] }
    func info(_ ref: PackageRef) async throws -> PackageDetails { throw EngineError(engine: id, message: "unused") }
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { wrapped.privilege(for: op, ref) }
    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        try wrapped.command(for: op, refs, options: options)
    }

    func installedDependents(of name: String) async throws -> Set<String> {
        let (found, fails) = lock.withLock { () -> (Set<String>, Bool) in
            _dependentsCalls.append(name)
            return (_dependents[name] ?? [], _failDependents.contains(name))
        }
        if let gate { await gate.wait() }
        if fails { throw EngineError(engine: id, message: "\(id.displayName) couldn't list dependents") }
        return found
    }

    /// Every name's dependents as `setDependents` gave them; throws when any name was set to fail.
    fileprivate func allDependents() throws -> [String: Set<String>] {
        let (all, fails) = lock.withLock { (_dependents, !_failDependents.isEmpty) }
        if fails { throw EngineError(engine: id, message: "\(id.displayName) couldn't list dependents") }
        return all
    }
}

/// A source like nanobrew: it builds the whole dependents map in one scan.
final class MappingFakeEngine: MoveFakeEngine, DependentsMapping, @unchecked Sendable {
    private var _mapCalls: [Duration?] = []
    var mapCalls: [Duration?] { lock.withLock { _mapCalls } }

    func installedDependentsMap(callTimeout: Duration?) async throws -> [String: Set<String>] {
        lock.withLock { _mapCalls.append(callTimeout) }
        return try allDependents()
    }
}

/// Homebrew has ripgrep (asked for), ripgrep-all (asked for, needs ripgrep) and pcre2 (a dependency of ripgrep);
/// nanobrew is the target and has both tools.
@MainActor struct MoveScenario {
    let catalog = FakeCatalog(engines: [.homebrew: .present(path: URL(fileURLWithPath: PlanFixtures.brewPath), version: "4"),
                                        .nanobrew: .present(path: URL(fileURLWithPath: PlanFixtures.nbPath), version: "1")])
    let executor: FakeRunExecutor
    let brew: MoveFakeEngine
    let nb = MoveFakeEngine(wrapping: PlanFixtures.engines[1])
    let model: BrewxPortAppModel

    static func formula(_ engine: EngineID, _ name: String, onRequest: Bool? = nil, fullName: String? = nil) -> Package {
        Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name, installedVersion: "1",
                latestVersion: "1", fullName: fullName, installedOnRequest: onRequest)
    }
    static let ripgrep = formula(.homebrew, "ripgrep", onRequest: true)
    static let ripgrepAll = formula(.homebrew, "ripgrep-all", onRequest: true)
    static let pcre2 = formula(.homebrew, "pcre2", onRequest: false)

    /// `mapping`: the source answers dependents with one map, as nanobrew does.
    /// `shellPath` and `path`: the PATH fix's editor (copy-only by default) and the login-shell PATH.
    init(executor: FakeRunExecutor = FakeRunExecutor(), isDemo: Bool = false,
         homebrew: [Package] = [ripgrep, ripgrepAll, pcre2], nanobrew: [Package] = [], mapping: Bool = false,
         shellPath: ShellPathEditor? = nil, path: any PathResolving = AppFixtures.NoPath()) {
        self.executor = executor
        brew = mapping ? MappingFakeEngine(wrapping: PlanFixtures.engines[0])
            : MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        let engines: [any Engine] = [brew, nb, PlanFixtures.engines[2], PlanFixtures.engines[3]]
        model = BrewxPortAppModel(services: AppFixtures.services(catalog: catalog, executor: executor, isDemo: isDemo,
                                                                engines: engines, path: path, shellPath: shellPath))
        catalog.script(.installed, .homebrew, packages: homebrew)
        catalog.script(.installed, .nanobrew, packages: nanobrew)
        brew.setDependents("ripgrep", ["ripgrep-all"])
        dependencies("ripgrep", ["pcre2"])
        dependencies("ripgrep-all", ["ripgrep"])
        dependencies("pcre2", [])
        onTarget("ripgrep")
        onTarget("ripgrep-all")
    }

    func dependencies(_ name: String, _ needs: [String]?) {
        catalog.scriptInfo(PackageRef(engine: .homebrew, kind: .formula, name: name),
                           .init(result: .success(PackageDetails(ref: PackageRef(engine: .homebrew, kind: .formula, name: name),
                                                                 dependencies: needs))))
    }

    func onTarget(_ name: String, as answered: String? = nil) {
        let ref = PackageRef(engine: .nanobrew, kind: .formula, name: name)
        // Like the real engines: the answer keeps the asked-for ref and says which package it found in reportedName.
        catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, latestVersion: "2", reportedName: answered ?? name))))
    }

    func failOnTarget(_ name: String, _ message: String) {
        catalog.scriptInfo(PackageRef(engine: .nanobrew, kind: .formula, name: name),
                           .init(result: .failure(EngineError(engine: .nanobrew, message: message))))
    }

    /// Loads Installed, then starts a move of `package` to nanobrew.
    func start(_ package: Package = ripgrep, to target: EngineID = .nanobrew) async {
        model.installed.reload()
        await model.installed.settled()
        model.move.start(package, to: target)
    }

    func ready() async -> MovePlan? {
        _ = await waitUntil { if case .checking = model.move.state { false } else { true } }
        if case .ready(let plan) = model.move.state { return plan }
        return nil
    }

    var installedQueries: Int { catalog.queries.filter { if case .installed = $0 { true } else { false } }.count }
}

@MainActor @Suite struct MoveModelTests {
    typealias S = MoveScenario

    /// Each step's operation and package arguments, for comparing run shapes.
    static func shape(_ steps: [RunStep]) -> [String] {
        steps.map { step in
            if let refs = step.verifyInstalled { return "check " + refs.map(\.name).joined(separator: " ") }
            return "\(step.operation) \(step.engine) " + step.spec.arguments.filter { !$0.hasPrefix("-") }
                .dropFirst().joined(separator: " ")
        }
    }

    @Test func startShowsCheckingThenReady() async throws {
        let s = S()
        let gate = Gate()
        s.brew.gate = gate
        await s.start()
        #expect(s.model.move.state == .checking)
        #expect(await waitUntil { gate.waiting == 1 })
        s.brew.gate = nil
        gate.release()
        let plan = try #require(await s.ready())
        #expect(plan.moving.map(\.old.id.name) == ["ripgrep", "ripgrep-all"])
        #expect(plan.moving.map(\.new.id) == [PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep"),
                                              PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep-all")])
        #expect(plan.cantMove.isEmpty)
        #expect(plan.leftovers.map(\.id.name) == ["pcre2"])
        #expect(plan.pathWarning == "ripgrep won't run from Terminal until /opt/nanobrew/prefix/bin is on your PATH.")
    }

    @Test func lookupFailureIsCantMove() async throws {
        let s = S()
        s.failOnTarget("ripgrep-all", "nanobrew didn't answer within 60 seconds")
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove == [CantMove(name: "ripgrep-all", reason: "nanobrew didn't answer in time")])
        #expect(plan.keepPicked)
        #expect(plan.moving.map(\.old.id.name) == ["ripgrep"])
        // Nothing runs until the person confirms the smaller move, and that keeps ripgrep's Homebrew copy.
        #expect(s.executor.runs.isEmpty)
        s.model.move.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        let steps = Self.shape(s.executor.runs[0].steps)
        #expect(!steps.contains { $0.hasPrefix("remove") })
    }

    @Test func targetInfoErrorWordedPlainly() async throws {
        let s = S()
        s.failOnTarget("ripgrep-all", "nb had no information for ripgrep-all")
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove == [CantMove(name: "ripgrep-all", reason: "couldn't find it on nanobrew")])
    }

    @Test func nameMismatchIsNotOnTarget() async throws {
        let s = S()
        s.onTarget("ripgrep-all", as: "ripgrep-all-ng")
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove == [CantMove(name: "ripgrep-all", reason: "not on nanobrew")])
    }

    @Test func nameDifferingOnlyInCaseIsTheSamePackage() async throws {
        let s = S()
        s.onTarget("ripgrep-all", as: "RipGrep-All")
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove.isEmpty)
        #expect(plan.moving.map(\.new.displayName) == ["ripgrep", "RipGrep-All"])
    }

    @Test func answerThatNamesNothingIsNotOnTarget() async throws {
        let s = S()
        let ref = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep-all")
        s.catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, latestVersion: "2"))))
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove == [CantMove(name: "ripgrep-all", reason: "not on nanobrew")])
    }

    @Test func homebrewAliasAnswerIsNotTheSamePackage() {
        // The real alias answer: asked for python3, Homebrew answered with python@3.15.
        let details = PackageDetails(ref: PackageRef(engine: .homebrew, kind: .formula, name: "python3"),
                                     reportedName: "python@3.15")
        #expect(MoveModel.lookup(details, for: "python3") == .notFound)
    }

    @Test func mappingSourceScansOnce() async throws {
        let s = S(mapping: true)
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.moving.map(\.old.id.name) == ["ripgrep", "ripgrep-all"])
        #expect(plan.leftovers.map(\.id.name) == ["pcre2"])
        let brew = try #require(s.brew as? MappingFakeEngine)
        #expect(brew.mapCalls == [s.model.move.queryTimeout])
        #expect(brew.dependentsCalls.isEmpty)
    }

    @Test func mappingSourceFailureFailsTheMove() async throws {
        let s = S(mapping: true)
        s.brew.failDependents("anything")
        await s.start()
        _ = await s.ready()
        guard case .failed(let message) = s.model.move.state else { Issue.record("not failed"); return }
        #expect(message.hasPrefix("BrewxPort couldn't find out what depends on ripgrep: "))
    }

    @Test func lookupsRunAtMostSixAtOnce() async throws {
        let meter = ConcurrentMapTestsMeter()
        let names = (0..<24).map { "p\($0)" }
        let result = await MoveModel.each(names) { name in
            meter.enter()
            try await Task.sleep(for: .milliseconds(5))
            meter.leave()
            return [name + "-user"]
        }
        guard case .success(let found) = result else { Issue.record("failed"); return }
        #expect(found.count == 24)
        #expect(meter.peak <= MoveModel.maxConcurrentCalls)
        #expect(meter.peak > 1)
        #expect(MoveModel.maxConcurrentCalls == 6)
    }

    // MARK: The run's summary line

    @Test func failedCheckSaysNothingWasRemoved() async throws {
        let s = S(executor: FakeRunExecutor(events: [.started(0), .finished(0, 1), .started(1), .finished(1, 1), .done]))
        s.executor.asksVerifier = true
        s.nb.installed = .success([S.formula(.nanobrew, "ripgrep")])
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        let line = "Nothing was removed because ripgrep-all isn't on nanobrew."
        #expect(await waitUntil { s.model.run.problems.contains(line) })
        #expect(s.model.run.log.lines.filter { $0.text == line }.count == 1)
        #expect(s.model.move.state == .hidden)
    }

    @Test func failedRemovalSaysWhichCopiesStay() async throws {
        let s = S(executor: FakeRunExecutor(events: [.started(0), .finished(0, 0), .started(1), .finished(1, 0),
                                                     .started(2), .finished(2, 1), .done]))
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        let line = "The Homebrew copies of ripgrep-all, ripgrep and pcre2 are still installed because removing "
            + "ripgrep-all failed."
        #expect(await waitUntil { s.model.run.problems.contains(line) })
    }

    @Test func successfulMoveAddsNoLine() async throws {
        let events: [RunEvent] = (0..<5).flatMap { [RunEvent.started($0), .finished($0, 0)] } + [.done]
        let s = S(executor: FakeRunExecutor(events: events))
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        #expect(await waitUntil { s.model.move.state == .hidden && !s.model.run.isRunning })
        #expect(s.model.run.problems.isEmpty)
        #expect(s.model.run.headline == "Finished")
    }

    @Test func alreadyOnTargetIsNotLookedUp() async throws {
        let s = S(nanobrew: [S.formula(.nanobrew, "RipGrep")])
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.moving.first?.needsInstall == false)
        #expect(!s.catalog.infoCalls.contains(PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")))
    }

    @Test func tapDependentCantMove() async throws {
        let s = S(homebrew: [S.ripgrep, S.formula(.homebrew, "ripgrep-all", onRequest: true, fullName: "me/tools/ripgrep-all"),
                             S.pcre2])
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.cantMove == [CantMove(name: "ripgrep-all", reason: "from a third-party tap")])
    }

    @Test func confirmStartsOneRun() async throws {
        let s = S()
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        #expect(s.model.move.state == .running)
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(Self.shape(s.executor.runs[0].steps) == [
            "install nanobrew ripgrep ripgrep-all",
            "check ripgrep ripgrep-all",
            "remove homebrew ripgrep-all",
            "remove homebrew ripgrep",
            "remove homebrew pcre2",
        ])
        #expect(await waitUntil { s.model.move.state == .hidden })
        #expect(s.executor.runs.count == 1)
    }

    /// The sheet counts as modal (so the Package menu and file panels stay off behind it), and its Move button still
    /// starts the run.
    @Test func confirmFromSheetStartsRun() async throws {
        let s = S()
        await s.start()
        #expect(s.model.modalUp)
        _ = try #require(await s.ready())
        #expect(s.model.modalUp)
        s.model.move.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(!s.model.modalUp)
    }

    @Test func failedSheetIsModalUntilClosed() async throws {
        let s = S()
        s.brew.failDependents("ripgrep")
        await s.start()
        _ = await s.ready()
        guard case .failed = s.model.move.state else { Issue.record("not failed"); return }
        #expect(s.model.modalUp)
        s.model.move.cancel()
        #expect(!s.model.modalUp)
    }

    /// Right-click and the Package menu offer the present managers that aren't the row's own (MacPorts is missing
    /// here), and picking one starts the check.
    @Test func menusOfferPresentTargetsAndStartTheCheck() async throws {
        let s = S()
        s.model.checkEnginesAgain()
        _ = await waitUntil { s.model.enginesChecked }
        s.model.installed.reload()
        await s.model.installed.settled()
        let ripgrep = S.ripgrep.id
        #expect(s.model.rowMenuItems(for: [ripgrep], in: .installed).filter { $0.isMove }.map(\.action)
                    == [.moveTo(.nanobrew)])
        s.model.sidebar = .installed
        #expect(s.model.moveMenuItems.isEmpty)
        s.model.installed.list.selection.selected = [ripgrep]
        #expect(s.model.moveMenuItems.map(\.action) == [.moveTo(.nanobrew)])
        #expect(s.model.moveMenuItems.allSatisfy { $0.isEnabled })
        s.model.installed.list.selection.selected = [ripgrep, S.pcre2.id]
        #expect(s.model.moveMenuItems.isEmpty)
        s.model.perform(.moveTo(.nanobrew), on: [ripgrep])
        let plan = try #require(await s.ready())
        #expect(plan.moving.map(\.old.id.name) == ["ripgrep", "ripgrep-all"])
        // The sheet is up: the menus' Move items are off.
        s.model.installed.list.selection.selected = [ripgrep]
        #expect(s.model.moveMenuItems.allSatisfy { !$0.isEnabled })
    }

    @Test func demoMenusShowMoveDisabled() async throws {
        let s = S(isDemo: true)
        s.model.checkEnginesAgain()
        _ = await waitUntil { s.model.enginesChecked }
        s.model.installed.reload()
        await s.model.installed.settled()
        let moves = s.model.rowMenuItems(for: [S.ripgrep.id], in: .installed).filter { $0.isMove }
        #expect(moves.map(\.action) == [.moveTo(.nanobrew)])
        #expect(moves.allSatisfy { !$0.isEnabled && $0.help == "Not available in demo mode" })
        s.model.perform(.moveTo(.nanobrew), on: [S.ripgrep.id])
        #expect(s.model.move.state == .hidden)
    }

    @Test func confirmWhileRunningDoesNothing() async throws {
        let s = S(executor: FakeRunExecutor(events: [], hang: true))
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        s.model.move.confirm()
        s.model.move.start(S.ripgrep, to: .nanobrew)
        s.model.move.cancel()
        #expect(s.model.move.state == .running)
        #expect(s.executor.runs.count == 1)
        s.model.run.cancel()
        #expect(await waitUntil { s.model.move.state == .hidden })
    }

    @Test func cancelHidesAndRunsNothing() async throws {
        let s = S()
        let gate = Gate()
        s.brew.gate = gate
        await s.start()
        #expect(await waitUntil { gate.waiting == 1 })
        s.model.move.cancel()
        #expect(s.model.move.state == .hidden)
        s.brew.gate = nil
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        // The check that was going is dropped.
        #expect(s.model.move.state == .hidden)
        s.model.move.confirm()

        // Cancelling a ready plan closes it too.
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.cancel()
        #expect(s.model.move.state == .hidden)
        s.model.move.confirm()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.executor.runs.isEmpty)
    }

    @Test func leftoversToggleChangesSteps() async throws {
        let s = S()
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.setRemoveLeftovers(false)
        guard case .ready(let plan) = s.model.move.state else { Issue.record("not ready"); return }
        #expect(!plan.removeLeftovers)
        s.model.move.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(!Self.shape(s.executor.runs[0].steps).contains("remove homebrew pcre2"))
        #expect(Self.shape(s.executor.runs[0].steps).contains("remove homebrew ripgrep"))
    }

    @Test func tooManyDependentsFails() async throws {
        let s = S()
        s.brew.setDependents("ripgrep", Set((1...200).map { "tool\($0)" }))
        await s.start()
        #expect(await waitUntil { s.model.move.state == .failed("Too many packages depend on ripgrep to move it here.") })
        #expect(s.catalog.infoCalls.isEmpty)
    }

    @Test func failedDependentsCallFails() async throws {
        let s = S()
        s.brew.failDependents("ripgrep-all")
        await s.start()
        #expect(await waitUntil {
            s.model.move.state == .failed("BrewxPort couldn't find out what depends on ripgrep: "
                                          + "Homebrew couldn't list dependents")
        })
    }

    @Test func sharedLibraryUsedOutsideIsNoLeftover() async throws {
        let s = S(homebrew: [S.ripgrep, S.ripgrepAll, S.pcre2, S.formula(.homebrew, "git", onRequest: true)])
        s.brew.setDependents("pcre2", ["ripgrep", "git"])
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.leftovers.isEmpty)
    }

    @Test func unknownDependenciesMeanNoLeftovers() async throws {
        let s = S()
        s.dependencies("ripgrep", nil)
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.moving.count == 2)
        #expect(plan.leftovers.isEmpty)
    }

    @Test func unknownRequestedMeansNoLeftovers() async throws {
        let s = S(homebrew: [S.ripgrep, S.ripgrepAll, S.formula(.homebrew, "pcre2")])
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.leftovers.isEmpty)
        #expect(plan.moving.allSatisfy { $0.wasRequested })
    }

    @Test func demoModeDoesNothing() async throws {
        let s = S(isDemo: true)
        await s.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.model.move.state == .hidden)
        #expect(s.brew.dependentsCalls.isEmpty)
    }

    @Test func addToPathWritesTheLineAndRefreshesThePath() async throws {
        let home = try ShellPathEditorTests.home()
        let path = CountingPath()
        let s = S(shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"), path: path)
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.pathBin == "/opt/nanobrew/prefix/bin")
        #expect(s.model.move.pathOffer == ShellPathEditorTests.appending(home, ".zprofile"))
        #expect(s.model.move.pathLine == ShellPathEditorTests.line)
        #expect(s.model.move.pathFix == .offered)
        let resolvesBefore = path.resolves
        s.model.move.addToPath()
        #expect(s.model.move.pathFix == .done(.added(file: "~/.zprofile")))
        #expect(try ShellPathEditorTests.read(home.appendingPathComponent(".zprofile")) == ShellPathEditorTests.line + "\n")
        // The cached PATH is dropped and asked for again, so the Runs column and later previews see the change.
        #expect(await waitUntil { path.forgets == 1 && path.resolves > resolvesBefore })
        // A second click finds it already there.
        s.model.move.addToPath()
        #expect(s.model.move.pathFix == .done(.alreadyPresent(file: "~/.zprofile")))
        // A new preview starts over.
        s.model.move.cancel()
        await s.start()
        _ = try #require(await s.ready())
        #expect(s.model.move.pathFix == .offered)
    }

    @Test func addToPathWritesTheFileTheSheetNamed() async throws {
        // .zshenv changes between the preview and the click: the line still goes where the caption said.
        let home = try ShellPathEditorTests.home()
        let dir = home.appendingPathComponent(".config/zsh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = S(shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"), path: CountingPath())
        await s.start()
        _ = try #require(await s.ready())
        #expect(s.model.move.pathOffer == ShellPathEditorTests.appending(home, ".zprofile"))
        try "export ZDOTDIR=$HOME/.config/zsh\n".write(to: home.appendingPathComponent(".zshenv"), atomically: false,
                                                       encoding: .utf8)
        s.model.move.addToPath()
        #expect(s.model.move.pathFix == .done(.added(file: "~/.zprofile")))
        #expect(try ShellPathEditorTests.read(home.appendingPathComponent(".zprofile"))
                    == ShellPathEditorTests.line + "\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".zprofile").path))
    }

    @Test func addToPathFailureSaysWhy() async throws {
        let home = try ShellPathEditorTests.home()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zprofile"),
                                                withIntermediateDirectories: false)
        let path = CountingPath()
        let s = S(shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"), path: path)
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.addToPath()
        #expect(s.model.move.pathFix == .failed("~/.zprofile isn't a regular file, so BrewxPort didn't change it."))
        #expect(path.forgets == 0)
    }

    @Test func otherShellCopiesTheLine() async throws {
        let home = try ShellPathEditorTests.home()
        let s = S(shellPath: ShellPathEditor(home: home, shell: "/opt/homebrew/bin/fish"))
        var copied: [String] = []
        s.model.writeToPasteboard = { copied.append($0) }
        await s.start()
        _ = try #require(await s.ready())
        #expect(s.model.move.pathOffer == .copyOnly(hint: nil))
        s.model.move.copyPathLine()
        #expect(copied == [ShellPathEditorTests.line])
        // Clicking Add anyway writes nothing.
        s.model.move.addToPath()
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func installedReloadedAfterMove() async throws {
        let s = S()
        await s.start()
        _ = try #require(await s.ready())
        let before = s.model.installed.reloadCount
        let queries = s.installedQueries
        s.model.move.confirm()
        #expect(await waitUntil { !s.model.run.isRunning && s.executor.runs.count == 1 })
        #expect(await waitUntil { s.model.installed.reloadCount == before + 1 })
        #expect(await waitUntil { s.installedQueries == queries + 1 })
        #expect(s.model.move.state == .hidden)
    }

    @Test func verifierReportsMissing() async throws {
        let s = S()
        s.nb.installed = .success([S.formula(.nanobrew, "RipGrep")])
        let ripgrep = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        let all = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep-all")
        #expect(await s.model.missingOnTarget([ripgrep, all]) == [all])

        // The move's run gets this verifier, not the fail-closed default.
        await s.start()
        _ = try #require(await s.ready())
        s.model.move.confirm()
        #expect(await waitUntil { s.executor.verifiers.count == 1 })
        #expect(await s.executor.verifiers[0]([ripgrep, all]) == [all])

        // A listing that fails counts every package as missing.
        s.nb.installed = .failure(EngineError(engine: .nanobrew, message: "nb broke"))
        #expect(await s.model.missingOnTarget([ripgrep, all]) == [ripgrep, all])
    }

    @Test func sameNamedCaskDoesNotSatisfyCheck() async {
        let s = S()
        s.nb.installed = .success([Package(id: PackageRef(engine: .nanobrew, kind: .cask, name: "Ripgrep"),
                                           displayName: "ripgrep")])
        let formula = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        #expect(await s.model.missingOnTarget([formula]) == [formula])
    }

    @Test func verifierTimesOutClosed() async {
        let ref = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        let slow = SlowEngine(wrapping: PlanFixtures.engines[1])
        #expect(await BrewxPortAppModel.missing([ref], engines: [slow], timeout: .milliseconds(50)) == [ref])
    }
}

/// An engine whose installed list never answers.
private final class SlowEngine: Engine, @unchecked Sendable {
    let wrapped: any Engine
    init(wrapping engine: any Engine) { wrapped = engine }
    var id: EngineID { wrapped.id }
    var capabilities: EngineCapabilities { wrapped.capabilities }
    var executableURL: URL? { wrapped.executableURL }
    func detect() async -> EngineStatus { .missing }
    func search(_ query: String) async throws -> [Package] { [] }
    func listInstalled() async throws -> [Package] {
        try await Task.sleep(for: .seconds(60))
        return []
    }
    func listOutdated() async throws -> [Package] { [] }
    func info(_ ref: PackageRef) async throws -> PackageDetails { throw EngineError(engine: id, message: "unused") }
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }
    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        try wrapped.command(for: op, refs, options: options)
    }
}

/// Counts calls in flight and the most at once.
final class ConcurrentMapTestsMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var _peak = 0
    var peak: Int { lock.withLock { _peak } }
    func enter() { lock.withLock { now += 1; _peak = max(_peak, now) } }
    func leave() { lock.withLock { now -= 1 } }
}

/// A login-shell PATH that counts how often it was asked and forgotten.
final class CountingPath: PathResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _resolves = 0
    private var _forgets = 0
    var resolves: Int { lock.withLock { _resolves } }
    var forgets: Int { lock.withLock { _forgets } }
    func resolve() async -> ResolvedPath {
        lock.withLock { _resolves += 1 }
        return ResolvedPath(entries: ["/usr/bin", "/bin"], source: .loginShell)
    }
    func forget() async { lock.withLock { _forgets += 1 } }
}
