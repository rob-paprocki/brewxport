import Foundation
import BrewxPortCore
import BrewxPortRun

/// The warning before a manual update of a Homebrew runtime that language tools run on (design option A), asked for
/// directly or brought along by another update (`UpdatesModel.runtimesBroughtAlong`).
public struct RuntimeWarning: Equatable, Sendable {
    /// "Update Ruby?"
    public let title: String
    /// What it breaks and where Repair tools is, one sentence per runtime, after what brings it along.
    public let message: String
    /// The update the person asked for, all of it, to run once they go ahead.
    let requests: [ActionRequest]
    /// The runtimes it updates, by ref.
    let holds: [PackageRef: RuntimeHold]
    /// For each of `holds`, the refs whose steps update it: the runtime itself, or what brings it along.
    let triggers: [PackageRef: Set<PackageRef>]
    /// The runtimes the person asked to update themselves (not only brought along).
    let direct: Set<PackageRef>

    /// Nil when none of `requests` updates a held runtime, directly or by bringing it along.
    init?(_ requests: [ActionRequest], holds: [PackageRef: RuntimeHold],
          broughtAlong: (PackageRef) -> [(runtime: PackageRef, certain: Bool)] = { _ in [] }) {
        var order: [PackageRef] = []
        var triggers: [PackageRef: Set<PackageRef>] = [:]
        var certainly: [PackageRef: [String]] = [:]
        var maybe: [PackageRef: [String]] = [:]
        let upgrades = requests.filter { $0.operation == .upgrade }
        let direct = Set(upgrades.map(\.package.id)).filter { holds[$0] != nil }
        for request in upgrades {
            let ref = request.package.id
            var runtimes: [(runtime: PackageRef, certain: Bool)] = direct.contains(ref) ? [(ref, true)] : []
            runtimes += broughtAlong(ref).filter { holds[$0.runtime] != nil && $0.runtime != ref }
            for (runtime, certain) in runtimes {
                if triggers[runtime] == nil { order.append(runtime) }
                triggers[runtime, default: [runtime]].insert(ref)
                guard runtime != ref, !direct.contains(runtime) else { continue }
                if certain {
                    certainly[runtime, default: []].append(request.package.displayName)
                } else {
                    maybe[runtime, default: []].append(request.package.displayName)
                }
            }
        }
        guard !order.isEmpty else { return nil }
        self.requests = requests
        self.holds = holds.filter { triggers[$0.key] != nil }
        self.triggers = triggers
        self.direct = direct
        let held = order.compactMap { holds[$0] }
        // "Update Python?" for one, "Update Python 3.13.9 and Python 3.14.1?" for two Pythons, never a name twice.
        var parts: [String] = []
        for hold in held {
            let versions = Set(held.filter { $0.runtime == hold.runtime }.map(\.version))
            let part = versions.count > 1 ? "\(hold.runtime) \(hold.version)" : hold.runtime
            if !parts.contains(part) { parts.append(part) }
        }
        title = "Update " + RuntimeHolds.list(parts) + "?"
        // What brings a runtime along: certainly when Homebrew's relations were read, "may" when they couldn't be.
        message = order.compactMap { ref -> String? in
            guard let hold = holds[ref] else { return nil }
            var along = ""
            if let names = certainly[ref] {
                along = "Updating " + RuntimeHolds.list(names) + " also updates \(hold.runtime). "
            } else if let names = maybe[ref] {
                along = "Updating " + RuntimeHolds.list(names) + " may also update \(hold.runtime). "
            }
            return along + hold.warning
        }.joined(separator: " ")
    }
}

/// Repair tools, offered on an engine's page once a runtime its tools run on changed.
public struct RepairOffer: Equatable, Sendable {
    /// "Ruby was updated, so your gems need reinstalling. Repair tools does that."
    public let line: String
    /// The tools Installed showed before the change, which may not be listed any more.
    let tools: [String]
}

/// A runtime change BrewxPort started, waiting for its run to end.
struct PendingRuntimeChange: Equatable, Sendable {
    let ref: PackageRef
    /// The refs whose steps change it: the runtime itself, and any update the person asked for that brings it along.
    var triggers: Set<PackageRef> = []
    /// Brought along only (its own step isn't in the run): Repair tools is offered only if Installed shows its version
    /// changed from `versionBefore` once the run's reload is in.
    var broughtAlongOnly = false
    var versionBefore: String?
    /// As the offer's line names it: "Ruby", or "python@3.15" for a removal.
    let runtime: String
    /// "updated" or "removed".
    let change: String
    /// The engines whose tools need repairing, each with the tools to repair.
    let engines: [EngineID: [String]]

    func offer(for engine: EngineID) -> RepairOffer {
        let tools = engine == .gem ? "your gems" : "your \(engine.displayName) tools"
        let need = engine == .npm ? "need rebuilding" : "need reinstalling"
        return RepairOffer(line: "\(runtime) was \(change), so \(tools) \(need). Repair tools does that.",
                           tools: self.engines[engine] ?? [])
    }
}

/// The PATH note on a language engine's page.
public struct PathNote: Equatable, Sendable {
    /// "~/.cargo/bin isn't on your PATH, so your shell doesn't find Cargo's tools."
    public let text: String
    /// The lines Add to PATH writes, one per folder, separated by newlines; nil when it writes none (a folder BrewxPort
    /// won't write, `ShellPathEditor.isPlainPath`, or a note that only names folders).
    public let line: String?
    /// The folders, as the engine reported them, in the order Add to PATH adds them.
    let bins: [String]

    /// One folder, with its line or none.
    init(text: String, line: String?, bin: String) {
        self.text = text
        self.line = line
        bins = [bin]
    }

    /// Several folders, each with its line when BrewxPort writes it.
    init(text: String, folders: [String]) {
        self.text = text
        let written = folders.filter(ShellPathEditor.isPlainPath)
        line = written.isEmpty ? nil : written.map(ShellPathEditor.line(for:)).joined(separator: "\n")
        bins = folders
    }
}

extension BrewxPortAppModel {
    /// The engines with Repair tools: npm rebuilds its globals, pipx, uv and RubyGems reinstall their tools.
    static let repairingEngines: Set<EngineID> = [.npm, .pipx, .uv, .gem]

    private func engine(_ id: EngineID) -> (any Engine)? { services.engines.first { $0.id == id } }

    // MARK: Where an engine writes

    /// Why this account can't change `engine`'s tools, with the fix, as its last detect found it; nil when it can.
    /// Once Homebrew's Ruby is installed beside a read-only RubyGems but isn't on the PATH, the fix is the PATH line
    /// (R30, `homebrewRubyPathNote`). Add to PATH checks the engine again itself; where the person adds the line
    /// (a shell BrewxPort doesn't write to, or a folder it won't write), they click Check again after.
    public func readOnlyReason(for engine: EngineID) -> String? {
        let reason = (self.engine(engine) as? any InstallLocationReporting)?.readOnlyReason
        guard engine == .gem, reason != nil, let aside = homebrewRubyAside(), let note = homebrewRubyPathNote() else {
            return reason
        }
        let then: String
        if case .append = pathOffer, note.line != nil { then = "." } else { then = ", then click Check again." }
        return "This is \(aside.ruby), and only an administrator can change its gems. Homebrew's Ruby is installed: add "
            + "it to your PATH below" + then
    }

    /// The language engines this account can't change: their tools aren't installed, updated or removed.
    var readOnlyEngines: Set<EngineID> { Set(readOnlyReasons.keys) }

    /// `readOnlyEngines`, each with why.
    var readOnlyReasons: [EngineID: String] {
        var reasons: [EngineID: String] = [:]
        for engine in services.engines {
            if let reason = (engine as? any InstallLocationReporting)?.readOnlyReason { reasons[engine.id] = reason }
        }
        return reasons
    }

    /// `ref` has an update on Updates that a read-only engine holds back (the inspector shows it, with Update off).
    public func hasReadOnlyUpdate(_ ref: PackageRef) -> Bool {
        updates.list.byRef[ref] != nil && readOnlyReason(for: ref.engine) != nil
    }

    /// The line on `engine`'s page when the copy it uses is a version manager's (nvm, fnm, asdf, mise, rbenv): its
    /// list is for that manager's current default version (`VersionManagers.note`). Nil otherwise.
    public func versionManagerNote(for engine: EngineID) -> String? {
        guard case .present(let path, _)? = engineStatuses[engine] else { return nil }
        return VersionManagers.note(for: engine, executable: path.path)
    }

    /// Where `engine` installs tools, as its page shows it (`~` for the home folder); nil when it didn't say.
    public func installLocation(for engine: EngineID) -> String? {
        (self.engine(engine) as? any InstallLocationReporting)?.installLocation
            .map { InstallAccess.shown(PathWinner.normalized($0.path), home: NSHomeDirectory()) }
    }

    // MARK: Holds

    /// After every Updates reload: the app's holds. Every update of a language engine this account can't change is
    /// held from every update (`accessHolds`); a Homebrew runtime update that would break language tools
    /// (`RuntimeHolds`) from automatic ones. The engines are asked which runtimes their tools use only when such an
    /// update is there. A reload that a newer one replaced (its task cancelled) writes nothing.
    ///
    /// For each held runtime, the updates `brew upgrade` would bring it along with are worked out too
    /// (`UpdatesModel.runtimesBroughtAlong`), from Installed once it has loaded, so neither an automatic run nor an
    /// unwarned manual one updates the runtime by the back door.
    func refreshAppHolds() async {
        let candidates = RuntimeHolds.candidates(updates.list.all.map(\.package))
        var runtime: [PackageRef: RuntimeHold] = [:]
        var relations: [PackageRef: HiddenRelations] = [:]
        if !candidates.isEmpty {
            let uses = await runtimeUses(of: Set(candidates.flatMap { RuntimeHolds.engines(for: $0.id.name) }))
            runtime = RuntimeHolds.holds(candidates, uses: uses)
        }
        if !runtime.isEmpty {
            await installed.settled()
            guard !Task.isCancelled else { return }
            let outdated = updates.list.all.map(\.id)
            let rows = installed.list.all.map(\.package)
            let failed = installed.list.failedEngines
            for ref in runtime.keys {
                guard let row = updates.list.byRef[ref] else { continue }
                relations[ref] = await HiddenRelations.gather(
                    for: [ref.engine], hidden: [row.package], outdated: outdated, installed: rows,
                    installedFailed: failed, engines: services.engines, catalog: services.catalog)
            }
        }
        guard !Task.isCancelled else { return }
        updates.runtimeHolds = runtime
        updates.runtimeRelations = relations
        updates.appHolds = accessHolds().merging(runtime.mapValues(\.hold)) { first, _ in first }
    }

    /// After a check of the engines (Check again, once the person fixed a folder): Updates' holds for engines this
    /// account can't change follow it at once, without a reload. The runtime holds stay as the last reload found them.
    func engineAccessChecked() {
        let holds = accessHolds().merging(updates.runtimeHolds.mapValues(\.hold)) { first, _ in first }
        if holds != updates.appHolds { updates.appHolds = holds }
    }

    /// Every Updates row of a language engine this account can't change, held from every update, pointing at its page.
    private func accessHolds() -> [PackageRef: UpdateHold] {
        var holds: [PackageRef: UpdateHold] = [:]
        let readOnly = readOnlyEngines
        for row in updates.list.all where readOnly.contains(row.id.engine) {
            let engine = row.id.engine
            holds[row.id] = UpdateHold(reason: "Your account can't change \(engine.possessive) tools. The "
                                       + "\(engine.displayName) page says how to fix that.", blocksAutomatic: true,
                                       blocksManual: true)
        }
        return holds
    }

    /// What each of `engines` that's installed says its tools run on, each within the usual query time: nil for one
    /// that couldn't say. An engine that isn't installed isn't in the answer. R45: one without an executable that the
    /// last check of the engines didn't find missing (its detect timed out or failed, or hasn't finished) may still be
    /// installed, so it couldn't say either (`mayBeInstalledUndetected`), never "not installed".
    func runtimeUses(of engines: Set<EngineID>) async -> [EngineID: [RuntimeUse]?] {
        let reporting = services.engines.filter { engines.contains($0.id) && $0 is any RuntimeReporting }
        let asked = reporting.filter { $0.executableURL != nil }
            .compactMap { engine in (engine as? any RuntimeReporting).map { (engine.id, $0) } }
        var answers: [EngineID: [RuntimeUse]?] = [:]
        for engine in reporting where mayBeInstalledUndetected(engine) { answers[engine.id] = .some(nil) }
        let found = await withTaskGroup(of: (EngineID, [RuntimeUse]?).self) { group in
            for (id, reporting) in asked {
                group.addTask { (id, await Self.withinQueryTime { try? await reporting.runtimeUses() }) }
            }
            var found: [EngineID: [RuntimeUse]?] = [:]
            for await (id, uses) in group { found[id] = .some(uses) }
            return found
        }
        return answers.merging(found) { _, asked in asked }
    }

    /// `work`'s answer, or nil when it takes longer than an engine query may.
    private nonisolated static func withinQueryTime<T: Sendable>(
        _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T??.self) { group in
            group.addTask { .some(await work()) }
            group.addTask {
                try? await Task.sleep(for: BrewxPortTimeouts.engineQuery)
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
    }

    // MARK: Keeping runtimes (R29)

    /// After every Installed load: the Homebrew runtimes (`node`, `ruby`, `python@3.x`) installed only as another
    /// package's dependency that language tools run on (`keptRuntimes`). An engine that couldn't say counts as running
    /// on it (the careful way). Only asked when there's such a runtime. A load that couldn't list Homebrew leaves it
    /// pending (`keptRuntimesPending`).
    func refreshKeptRuntimes() {
        keptRuntimesAsked += 1
        let asked = keptRuntimesAsked
        let candidates = installed.list.all.map(\.package).filter { (package: Package) -> Bool in
            let ref = package.id
            guard ref.engine == .homebrew, ref.kind == .formula, package.installedOnRequest == false else { return false }
            return !RuntimeHolds.engines(for: ref.name).isEmpty
        }
        guard !candidates.isEmpty else {
            keptRuntimes = [:]
            // Installed couldn't list Homebrew: no candidate then says nothing, so it stays pending (autoremove off)
            // until a load that did list Homebrew.
            keptRuntimesPending = installed.list.failedEngines.contains(.homebrew)
            return
        }
        // Until the engines answer, every such runtime counts as kept (failing closed), so an update started meanwhile
        // (the launch check's) still runs with autoremove off.
        keptRuntimes = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, RuntimeHolds.engines(for: $0.id.name)) })
        keptRuntimesPending = true
        Task { [weak self] in
            guard let self else { return }
            let uses = await self.runtimeUses(of: Set(candidates.flatMap { RuntimeHolds.engines(for: $0.id.name) }))
            guard asked == self.keptRuntimesAsked else { return }
            var kept: [PackageRef: [EngineID]] = [:]
            for runtime in candidates {
                let engines = RuntimeHolds.engines(for: runtime.id.name).filter { engine in
                    guard let answer = uses[engine] else { return false }
                    return answer?.contains { $0.formula == runtime.id.name } ?? true
                }
                if !engines.isEmpty { kept[runtime.id] = engines }
            }
            self.keptRuntimes = kept
            self.keptRuntimesPending = false
        }
    }

    /// `plan` with Homebrew's updates told not to autoremove anything while a runtime language tools run on is only a
    /// dependency (`keptRuntimes`): its cleanup would otherwise remove it once nothing else needs it. Otherwise as it is.
    ///
    /// Before any answer (`keptRuntimesPending`: launch, before Installed has loaded, or while the engines are asked)
    /// it fails closed: autoremove is off.
    func keepingRuntimes(_ plan: ActionPlan) -> ActionPlan {
        guard keptRuntimesPending || !keptRuntimes.isEmpty else { return plan }
        let steps = plan.steps.map { step in
            step.engine == .homebrew && step.operation == .upgrade
                ? step.addingUserEnvironment(MoveRunBuilder.homebrewRemovalEnvironment) : step
        }
        return ActionPlan(steps: steps, problems: plan.problems, notes: plan.notes, reason: plan.reason)
    }

    /// The line on `engine`'s page when Homebrew would otherwise autoremove a runtime its tools run on; nil otherwise.
    public func keptRuntimeNote(for engine: EngineID) -> String? {
        guard !keptRuntimesPending else { return nil }
        let runtimes = keptRuntimes.filter { $0.value.contains(engine) }.keys.map(\.name).sorted()
        guard !runtimes.isEmpty else { return nil }
        let names = RuntimeHolds.list(runtimes)
        return "Homebrew installed \(names) only as another package's dependency. \(engine.possessive) tools run on "
            + (runtimes.count == 1 ? "it" : "them") + ", so BrewxPort keeps Homebrew from removing "
            + (runtimes.count == 1 ? "it" : "them") + " when it updates."
    }

    // MARK: The runtime warning

    /// The warning before `requests` run (`RuntimeWarning`); nil when none of them updates a held runtime, directly or
    /// by bringing it along.
    ///
    /// While a reload's holds are still being worked out (`UpdatesModel.pruning`: from the reload until
    /// `refreshAppHolds` has the engines' answers and Homebrew's relations, which can take a while, as at launch), it
    /// fails closed, as R29 does: every runtime update on Updates that could break tools (`RuntimeHolds.breaks`) and
    /// has no hold yet counts as held for each installed engine whose tools could run on it, and any update from its
    /// package manager may bring it along. So an update started then still asks first, and the run still offers
    /// Repair tools afterwards.
    func warningBefore(_ requests: [ActionRequest]) -> RuntimeWarning? {
        var holds = updates.runtimeHolds
        var relations = updates.runtimeRelations
        if updates.pruning {
            let pending = RuntimeHolds.holds(updates.list.all.map(\.package), uses: unansweredRuntimeUses())
            for (ref, hold) in pending where holds[ref] == nil {
                holds[ref] = hold
                relations[ref] = nil
            }
        }
        return RuntimeWarning(requests, holds: holds) {
            UpdatesModel.broughtAlong(by: $0, holds: holds, relations: relations)
        }
    }

    /// Every engine that says what its tools run on and may be installed, as one that couldn't say: the careful
    /// reading (`RuntimeHolds.holds`), which counts its tools as running on every runtime they could. R44: that's one
    /// with an executable, and one without (`mayBeInstalledUndetected`). Only one found missing is left out.
    private func unansweredRuntimeUses() -> [EngineID: [RuntimeUse]?] {
        var uses: [EngineID: [RuntimeUse]?] = [:]
        for engine in services.engines where engine is any RuntimeReporting {
            guard engine.executableURL != nil || mayBeInstalledUndetected(engine) else { continue }
            uses[engine.id] = .some(nil)
        }
        return uses
    }

    /// R44/R45: an engine without an executable that the last check of the engines didn't find missing. A language
    /// engine has no executable until its first detect finishes, which can wait for the login shell (at launch, none
    /// answered yet), and one whose detect timed out or failed is `.unusable`: either may be installed.
    private func mayBeInstalledUndetected(_ engine: any Engine) -> Bool {
        guard engine.executableURL == nil else { return false }
        if case .missing? = engineStatuses[engine.id] { return false }
        return true
    }

    /// The warning's Update: the update the person asked for runs, and once it has, the engines whose tools ran on
    /// the runtime offer Repair tools for the tools Installed shows now.
    public func confirmRuntimeUpdate() {
        guard let warning = runtimeWarning else { return }
        runtimeWarning = nil
        let changes = warning.holds.map { ref, hold in
            PendingRuntimeChange(ref: ref, triggers: warning.triggers[ref] ?? [ref],
                                 broughtAlongOnly: !warning.direct.contains(ref),
                                 versionBefore: installed.list.byRef[ref]?.package.installedVersion
                                    ?? updates.list.byRef[ref]?.package.installedVersion,
                                 runtime: hold.runtime, change: "updated",
                                 engines: Dictionary(uniqueKeysWithValues: hold.engines.map { engine, tools in
                                     (engine, installedTools(engine, plus: tools))
                                 }))
        }
        guard proceed(warning.requests, origin: .user) else { return }
        pendingRuntimeChanges += changes
    }

    public func cancelRuntimeUpdate() {
        runtimeWarning = nil
    }

    /// Installed's tools from `engine`, with `more`, sorted.
    func installedTools(_ engine: EngineID, plus more: [String] = []) -> [String] {
        Set(installed.list.all.filter { $0.id.engine == engine }.map(\.id.name)).union(more).sorted()
    }

    /// A runtime change the uninstall sheet is about to start (removing a Python tools run on).
    func runtimeChangeStarting(_ change: PendingRuntimeChange) {
        pendingRuntimeChanges.append(change)
    }

    /// After every run: each runtime change it had (a step named the runtime, or an update that brings it along)
    /// offers Repair tools on its engines' pages, unless no such step ran. A step that failed may still have changed
    /// it, so it offers them too: a repair that wasn't needed does no harm.
    ///
    /// A runtime only brought along by another update (its own step isn't in the run) offers them only once the run's
    /// reload shows its version changed: Homebrew may have left it alone (the relation was only possible, or it had
    /// nothing to do).
    func runtimeChangesEnded() {
        guard !pendingRuntimeChanges.isEmpty else { return }
        let rows = run.steps
        var toCheck: [PendingRuntimeChange] = []
        pendingRuntimeChanges.removeAll { change in
            let triggers = change.triggers.union([change.ref])
            let mine = rows.filter { !triggers.isDisjoint(with: $0.refs) }
            guard !mine.isEmpty else { return false }
            if mine.contains(where: { $0.state != .waiting && $0.state != .skipped }) {
                if change.broughtAlongOnly {
                    toCheck.append(change)
                } else {
                    for engine in change.engines.keys { repairOffers[engine] = change.offer(for: engine) }
                }
            }
            return true
        }
        guard !toCheck.isEmpty else { return }
        // Runs after the run end's reload has started (this is called just before it, in the same turn).
        Task { [weak self] in
            guard let self else { return }
            await self.installed.settled()
            for change in toCheck {
                let now = self.installed.list.byRef[change.ref]?.package.installedVersion
                guard now != change.versionBefore else { continue }
                for engine in change.engines.keys { self.repairOffers[engine] = change.offer(for: engine) }
            }
        }
    }

    // MARK: Repair tools

    /// The line on `engine`'s page after a runtime its tools run on changed; nil otherwise.
    public func repairOffer(for engine: EngineID) -> String? { repairOffers[engine]?.line }

    /// Whether `engine`'s page can start Repair tools now: an engine that has it, installed, whose tools this account
    /// can change, while nothing else is going.
    public func canRepair(_ engine: EngineID) -> Bool {
        guard Self.repairingEngines.contains(engine), canRun, !busy, !modalUp,
              self.engine(engine)?.executableURL != nil, readOnlyReason(for: engine) == nil else { return false }
        return true
    }

    /// Repair tools: the engine's repair steps for Installed's tools and any the last runtime change left unlisted,
    /// as one run of the person's. The tools it won't repair automatically are in the run panel, each with why.
    public func repairTools(_ engine: EngineID) {
        guard canRepair(engine), let repairing = self.engine(engine) as? any ToolRepairing else { return }
        let tools = installedTools(engine, plus: repairOffers[engine]?.tools ?? [])
        var steps: [RunStep] = []
        var problems: [String] = []
        do {
            steps = try repairing.repairCommands(for: tools).map { command in
                RunStep(engine: engine, kind: .tool, operation: .repair, spec: command.spec,
                        title: "\(engine.displayName): \(command.tool ?? "all tools")",
                        refs: command.tool.map { [PackageRef(engine: engine, kind: .tool, name: $0)] } ?? [])
            }
        } catch {
            let message = (error as? EngineError).map(EngineErrorText.line) ?? "\(error)"
            problems.append("BrewxPort couldn't repair \(engine.possessive) tools: \(message)")
        }
        // A tool the engine won't repair automatically (R28: uv's tool installed from git) is named, with why.
        let refusals = repairing.repairRefusals(for: tools)
        problems += refusals.keys.sorted().compactMap { refusals[$0] }
        requestedUpgrades = []
        let plan = ActionPlan(steps: steps, problems: problems, notes: [],
                              reason: ActionPlanner.reason(for: [.repair]))
        if start(plan) { repairOffers[engine] = nil }
    }

    // MARK: The PATH note

    /// R30: Homebrew's Ruby is installed (the last listing of Homebrew that worked has `ruby`, `homebrewFormulae`), but
    /// RubyGems still runs macOS's or MacPorts' Ruby, which the login shell finds first. `folder` is
    /// `<prefix>/opt/ruby/bin`, which holds Homebrew's gem whether or not the formula is linked; `ruby` names the Ruby
    /// the shell runs instead. Nil otherwise.
    func homebrewRubyAside() -> (folder: String, ruby: String)? {
        guard case .present(let gem, _)? = engineStatuses[.gem],
              case .homebrew(let formula, let prefix)? = EngineSetupPlanner.languageRoute(.gem, statuses: engineStatuses),
              homebrewFormulae?.contains(formula) == true else { return nil }
        switch GemEngine.rubySource(gemPath: gem.path) {
        case .system?: return (prefix + "/opt/ruby/bin", "macOS's own Ruby")
        case .macports?: return (prefix + "/opt/ruby/bin", "MacPorts' Ruby")
        default: return nil
        }
    }

    /// R30: RubyGems' PATH note while `homebrewRubyAside` holds and its folder isn't on the login shell's PATH: Add to
    /// PATH puts Homebrew's Ruby first. RubyGems stays read-only until the shell finds it (Check again).
    func homebrewRubyPathNote() -> PathNote? {
        guard let aside = homebrewRubyAside(), let entries = installed.loginPath else { return nil }
        let folder = PathWinner.normalized(aside.folder)
        guard !entries.map(PathWinner.normalized).contains(folder) else { return nil }
        let shown = InstallAccess.shown(folder, home: NSHomeDirectory())
        return PathNote(text: "Homebrew's Ruby is installed, but \(shown) isn't on your PATH, so your shell still runs "
                        + "\(aside.ruby).",
                        line: ShellPathEditor.isPlainPath(folder) ? ShellPathEditor.line(for: folder) : nil, bin: folder)
    }

    /// Fix round 1: Homebrew's node is installed beside a read-only npm, but the login shell runs another npm first.
    /// The note names both folders; BrewxPort doesn't change the PATH for it (the other Node may be wanted). Not for
    /// Volta's npm, which is read-only for Volta's own reason (`NpmEngine.voltaReason`): its page says that.
    func otherNpmFirstNote() -> PathNote? {
        guard case .present(let npm, _)? = engineStatuses[.npm], let reason = readOnlyReason(for: .npm),
              reason != NpmEngine.voltaReason,
              case .homebrew(let formula, let prefix)? = EngineSetupPlanner.languageRoute(.npm, statuses: engineStatuses),
              homebrewFormulae?.contains(formula) == true, installed.loginPath != nil else { return nil }
        let runs = PathWinner.normalized(npm.deletingLastPathComponent().path)
        let homebrews = prefix + "/bin"
        guard runs != homebrews else { return nil }
        let shown = InstallAccess.shown(runs, home: NSHomeDirectory())
        return PathNote(text: "Your shell runs npm from \(shown); Homebrew's is in \(homebrews).", line: nil,
                        bin: homebrews)
    }

    /// Fix round 1: Cargo found in Homebrew's keg-only rustup (as `ToolLocator` resolves it,
    /// `<prefix>/Cellar/rustup/<version>/bin`, or `<prefix>/opt/rustup/bin`): the folder a PATH line should name,
    /// `<prefix>/opt/rustup/bin` (it outlives rustup's updates), and the one cargo was found in. Nil otherwise.
    func homebrewRustupKeg() -> (folder: String, found: String)? {
        guard case .present(let cargo, _)? = engineStatuses[.cargo] else { return nil }
        let found = PathWinner.normalized(cargo.deletingLastPathComponent().path)
        if found.hasSuffix("/opt/rustup/bin") { return (found, found) }
        let parts = found.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 5, parts[parts.count - 4] == "Cellar", parts[parts.count - 3] == "rustup",
              parts.last == "bin" else { return nil }
        let prefix = parts.dropLast(4).joined(separator: "/")
        return (prefix + "/opt/rustup/bin", found)
    }

    /// The PATH note for `engine`'s page: its bin folder isn't on the login shell's PATH (as Installed last read it).
    /// Nil when it is, when the engine didn't say where its commands go, or when the login shell didn't answer.
    /// RubyGems on macOS's or MacPorts' Ruby with Homebrew's installed beside it gets `homebrewRubyPathNote` instead;
    /// npm run from elsewhere with Homebrew's node installed, `otherNpmFirstNote`. Cargo in Homebrew's keg-only rustup
    /// also names the keg folder (`homebrewRustupKeg`), where cargo and rustup are, beside the one its crates go in.
    public func pathNote(for engine: EngineID) -> PathNote? {
        if engine == .gem, let note = homebrewRubyPathNote() { return note }
        if engine == .npm, let note = otherNpmFirstNote() { return note }
        guard engine.isLanguage, let entries = installed.loginPath else { return nil }
        let onPath = Set(entries.map(PathWinner.normalized))
        var keg: String?
        if engine == .cargo, let found = homebrewRustupKeg(), !onPath.contains(found.folder),
           !onPath.contains(found.found) {
            keg = found.folder
        }
        let bin = (self.engine(engine) as? any InstallLocationReporting)?.binLocation
            .map { PathWinner.normalized($0.path) }.flatMap { onPath.contains($0) ? nil : $0 }
        if let keg {
            guard let bin else {
                return PathNote(text: "\(keg) isn't on your PATH, so your shell doesn't find Homebrew's cargo and "
                                + "rustup.", folders: [keg])
            }
            let shown = InstallAccess.shown(bin, home: NSHomeDirectory())
            return PathNote(text: "\(keg) and \(shown) aren't on your PATH, so your shell doesn't find Homebrew's cargo "
                            + "or the tools Cargo installs.", folders: [keg, bin])
        }
        guard let folder = bin else { return nil }
        let shown = InstallAccess.shown(folder, home: NSHomeDirectory())
        let text = "\(shown) isn't on your PATH, so your shell doesn't find \(engine.possessive) tools."
        // RubyGems' bin folder is inside its Ruby version's gem folder (Homebrew's `lib/ruby/gems/4.0.0/bin`), and
        // Homebrew documents no folder that stays: a line added now would point at the old folder after the next Ruby
        // minor update. So it's named, never added.
        guard engine != .gem else {
            return PathNote(text: text + " Its name changes with each Ruby minor version, so BrewxPort doesn't add it "
                            + "for you.", line: nil, bin: folder)
        }
        return PathNote(text: text, line: ShellPathEditor.isPlainPath(folder) ? ShellPathEditor.line(for: folder) : nil,
                        bin: folder)
    }

    /// Whether Add to PATH writes a file, or offers the line to copy.
    public var pathOffer: ShellPathEditor.Offer {
        if let cachedPathOffer { return cachedPathOffer }
        let offer = services.shellPath.offer
        cachedPathOffer = offer
        return offer
    }

    public func pathFix(for engine: EngineID) -> MoveModel.PathFix { pathFixes[engine] ?? .offered }

    /// Add to PATH on `engine`'s page: the note's lines go into the login shell's startup file (the one `pathOffer`
    /// names), one per folder, then the shell is asked again and the engines are detected again, as Check again does
    /// (post-VM fix: RubyGems kept showing macOS's Ruby until then). Only on a click, never in demo mode, and never
    /// for a folder BrewxPort won't write. It says "added" when any line was added.
    public func addToPath(_ engine: EngineID) {
        guard !services.isDemo, let note = pathNote(for: engine), note.line != nil else { return }
        do {
            var outcome: ShellPathEditor.Outcome?
            for bin in note.bins where ShellPathEditor.isPlainPath(bin) {
                let result = try services.shellPath.add(bin, to: pathOffer, allowing: Set(note.bins))
                if case .added = result { outcome = result } else if outcome == nil { outcome = result }
            }
            guard let outcome else { return }
            pathFixes[engine] = .done(outcome)
            cachedPathOffer = nil
            installed.pathChanged()
            checkEnginesAgainSoon()
        } catch {
            pathFixes[engine] = .failed(MoveSheetText.pathFixFailure(error))
        }
    }

    /// The Copy button for a shell BrewxPort doesn't edit.
    public func copyPathLine(_ engine: EngineID) {
        guard let line = pathNote(for: engine)?.line else { return }
        writeToPasteboard(line)
    }
}
