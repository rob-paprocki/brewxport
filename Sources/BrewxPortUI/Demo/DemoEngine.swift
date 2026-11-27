import Foundation
import BrewxPortCore
import BrewxPortRun

/// What demo mode has "installed": read once from the fixtures, then changed only by `DemoRunExecutor`, until a
/// Check Now puts it back (`reset()`).
public actor DemoInventory {
    private var installed: [EngineID: [Package]]
    /// Each engine's outdated check as the fixtures answered it: its updates, what it couldn't check, its holds.
    private var outdated: [EngineID: OutdatedReport]
    /// Homebrew's third-party taps, as `brew tap` lists them (lowercase).
    private var taps: [String]
    /// Every row a search has shown, so an install knows the package's name, summary and version.
    private var known: [PackageRef: Package] = [:]
    /// The lists as the fixtures had them at launch.
    private let launch: (installed: [EngineID: [Package]], outdated: [EngineID: OutdatedReport], taps: [String])

    public init(installed: [EngineID: [Package]], outdated: [EngineID: OutdatedReport], taps: [String] = []) {
        self.installed = installed
        self.outdated = outdated
        self.taps = taps
        launch = (installed, outdated, taps)
    }

    public init(installed: [EngineID: [Package]], outdated: [EngineID: [Package]], taps: [String] = []) {
        self.init(installed: installed, outdated: outdated.mapValues { OutdatedReport(packages: $0) }, taps: taps)
    }

    /// The demo's Check Now: back to the lists the fixtures had at launch, so a check finds the fixture updates
    /// again. Installed and the taps go back too, so Installed agrees with Updates; what searches showed is kept.
    func reset() {
        (installed, outdated, taps) = launch
    }

    func installed(_ engine: EngineID) -> [Package] { installed[engine] ?? [] }
    func outdated(_ engine: EngineID) -> [Package] { outdated[engine]?.packages ?? [] }
    func outdatedReport(_ engine: EngineID) -> OutdatedReport { outdated[engine] ?? OutdatedReport(packages: []) }
    func installedTaps() -> [String] { taps }

    func remember(_ packages: [Package]) {
        for package in packages { known[package.id] = package }
    }

    /// The row for `ref`: outdated first (it has both versions), then installed, then what a search showed.
    func package(_ ref: PackageRef) -> Package? {
        outdated[ref.engine]?.packages.first { $0.id == ref } ?? installed[ref.engine]?.first { $0.id == ref }
            ?? known[ref]
    }

    /// Nil when the inventory doesn't have `ref` installed.
    func installedVersion(_ ref: PackageRef) -> String? {
        installed[ref.engine]?.first { $0.id == ref }?.installedVersion
    }

    /// What the step would have done. Steps are batched, so the packages are the step's arguments that name one;
    /// anything else (flags, variants) is skipped. This assumes no package is named like a verb or flag the step
    /// also carries ("install", "-N", "--cask", "--formula", "tap", uv's "tool" and "never", Bun's "add", "update"
    /// and "remove"); the captured fixtures have none.
    ///
    /// An install of a package no search showed (a bundle or Brewfile row) gets a row made from its argument, the way
    /// `brew info --installed` lists it: a tap-qualified `user/repo/name` becomes `name` with that full name. Its
    /// version isn't known. `brew tap user/repo` adds the tap.
    func apply(_ step: RunStep) {
        let engine = step.engine
        let names = Set(step.spec.arguments.flatMap { argument in
            [argument] + [Self.packageName(argument, engine: engine)].compactMap { $0 }
        })
        switch step.operation {
        case .install where step.kind == .tap:
            for tap in Self.packageArguments(step) where !taps.contains(tap.lowercased()) {
                taps.append(tap.lowercased())
            }
        case .install:
            var adding = known.values.filter {
                $0.id.engine == engine && (names.contains($0.id.name) || $0.fullName.map(names.contains) == true)
            }
            if adding.isEmpty {
                // A nanobrew cask routed to Homebrew: the row came from nanobrew's search.
                adding = known.values
                    .filter { $0.id.kind == step.kind && names.contains($0.id.name) }
                    .map { found in
                        var row = found
                        row.id = PackageRef(engine: engine, kind: found.id.kind, name: found.id.name)
                        return row
                    }
            }
            let named = Set(adding.flatMap { [$0.id.name] + [$0.fullName].compactMap { $0 } })
            for argument in Self.packageArguments(step) where !named.contains(argument) {
                let bare = String(argument.split(separator: "/").last ?? Substring(argument))
                adding.append(Package(id: PackageRef(engine: engine, kind: step.kind, name: bare), displayName: bare,
                                      fullName: bare == argument ? nil : argument))
            }
            for var row in adding where !(installed[engine] ?? []).contains(where: { $0.id == row.id }) {
                row.installedVersion = row.latestVersion ?? row.installedVersion
                // The demo installs only what was picked, never a dependency.
                row.installedOnRequest = true
                installed[engine, default: []].append(row)
            }
        case .upgrade:
            let upgraded = (outdated[engine]?.packages ?? []).filter { names.contains($0.id.name) }
            outdated[engine]?.packages.removeAll { names.contains($0.id.name) }
            outdated[engine]?.held.removeAll { names.contains($0.package.id.name) }
            for row in upgraded {
                let version = row.latestVersion ?? row.installedVersion
                if let index = installed[engine]?.firstIndex(where: { $0.id == row.id }) {
                    installed[engine]?[index].installedVersion = version
                    installed[engine]?[index].latestVersion = version
                } else {
                    var added = row
                    added.installedVersion = version
                    installed[engine, default: []].append(added)
                }
            }
        case .remove:
            installed[engine]?.removeAll { names.contains($0.id.name) }
            outdated[engine]?.packages.removeAll { names.contains($0.id.name) }
            outdated[engine]?.held.removeAll { names.contains($0.package.id.name) }
        case .markRequested, .markDependency, .repair:
            // A repair changes no versions, and its arguments (`rebuild`, `reinstall-all`) name no package.
            break
        }
    }

    /// The step's arguments that name a package or tap: not the verb (uv's is two words, `tool install`; Bun's is
    /// `add`), a flag (`-N`, `--cask`), a flag's value (uv's `--color never`, Mint's `--overwrite n`, Cargo's
    /// `--version =16.0.0` and the options an upgrade passes again) or a variant (`+x`). Mint's `owner/repo@tag` names
    /// `owner/repo` (`packageName`).
    private static func packageArguments(_ step: RunStep) -> [String] {
        let verbs: Set<String> = ["install", "tap", "tool", "add"]
        let flagsWithValues: Set<String> = ["--color", "--overwrite", "--version", "--bin", "--features", "--profile",
                                            "--target"]
        var names: [String] = []
        var isValue = false
        for argument in step.spec.arguments {
            defer { isValue = flagsWithValues.contains(argument) }
            guard !isValue, !verbs.contains(argument), !argument.hasPrefix("-"), !argument.hasPrefix("+") else {
                continue
            }
            names.append(step.engine == .mint ? packageName(argument, engine: .mint) ?? argument : argument)
        }
        return names
    }

    /// The package an argument names besides itself: npm upgrades by installing `name@latest`; Mint installs
    /// `owner/repo@tag` and uninstalls the repository's URL. Nil for any other argument.
    private static func packageName(_ argument: String, engine: EngineID) -> String? {
        if argument.hasSuffix("@latest") { return String(argument.dropLast("@latest".count)) }
        guard engine == .mint else { return nil }
        if let name = MintEngine.packageName(repository: argument) { return name }
        return argument.lastIndex(of: "@").map { String(argument[..<$0]) }
    }
}

/// A real engine on a `FixtureRunner`, with its installed and outdated lists kept in a shared `DemoInventory`.
///
/// Searches go through the real engine's parser on the captured search and keep the rows whose name contains the
/// query. Commands and privileges are the real engine's, so the steps a demo run shows are the ones BrewxPort would run.
public final class DemoEngine: Engine, TapListing, DependentsListing, CatalogRefreshing, InstallLocationReporting,
                                EngineNoteReporting, RuntimeReporting, ToolRepairing, ExecutableNaming {
    public let runner: FixtureRunner
    let wrapped: any Engine
    let inventory: DemoInventory
    private let host: Arch

    public init(wrapping engine: any Engine, runner: FixtureRunner, inventory: DemoInventory, host: Arch) {
        wrapped = engine
        self.runner = runner
        self.inventory = inventory
        self.host = host
    }

    public var id: EngineID { wrapped.id }
    public var capabilities: EngineCapabilities { wrapped.capabilities }
    public var executableURL: URL? { wrapped.executableURL }
    public var runArch: Arch { host }

    public func detect() async -> EngineStatus { await wrapped.detect() }

    /// The wrapped engine's install location (npm's global prefix, from the fixtures); nil for an engine without one.
    public var installLocation: URL? { (wrapped as? any InstallLocationReporting)?.installLocation }

    /// The wrapped engine's note on its last listing (uv's); nil for an engine without one.
    public var note: String? { (wrapped as? any EngineNoteReporting)?.note }

    /// The wrapped engine's bin folder, from the fixtures; nil for an engine without one.
    public var binLocation: URL? { (wrapped as? any InstallLocationReporting)?.binLocation }

    /// The wrapped engine's answer: demo engines are made with folders that count as writable, so nil unless the
    /// fixtures' Ruby is one BrewxPort never installs into.
    public var readOnlyReason: String? { (wrapped as? any InstallLocationReporting)?.readOnlyReason }

    /// The wrapped engine's runtimes, from the fixtures; none for an engine without them.
    public func runtimeUses() async throws -> [RuntimeUse] {
        try await (wrapped as? any RuntimeReporting)?.runtimeUses() ?? []
    }

    /// The wrapped engine's repair steps (a demo run only simulates them); a refusal for an engine without them.
    public func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        guard let repairing = wrapped as? any ToolRepairing else {
            throw EngineError(engine: id, message: "\(id.displayName) has no tools to repair")
        }
        return try repairing.repairCommands(for: tools)
    }

    /// The wrapped engine's refusals; none for an engine without repairs.
    public func repairRefusals(for tools: [String]) -> [String: String] {
        (wrapped as? any ToolRepairing)?.repairRefusals(for: tools) ?? [:]
    }

    /// The wrapped engine's answer; nil for an engine that can't name its tools' commands.
    public func executables(of name: String) -> [String]? {
        (wrapped as? any ExecutableNaming)?.executables(of: name)
    }

    /// A search that reads a registry answer the fixtures don't have (pipx's and uv's exact-name lookup) finds
    /// nothing. A command the fixtures don't map is a gap in them, and fails like any engine error.
    public func search(_ query: String) async throws -> [Package] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let answered: [Package]
        do {
            answered = try await wrapped.search(query)
        } catch FixtureRunnerError.unmappedURL {
            answered = []
        }
        let found = answered.filter {
            $0.displayName.lowercased().contains(needle) || $0.id.name.lowercased().contains(needle)
        }
        await inventory.remember(found)
        return found
    }

    public func listInstalled() async throws -> [Package] { await inventory.installed(id) }
    public func listOutdated() async throws -> [Package] { await inventory.outdated(id) }
    /// The fixtures' outdated check, less what demo runs updated: its holds and what it couldn't check too.
    public func checkOutdated() async throws -> OutdatedReport { await inventory.outdatedReport(id) }

    /// The inventory's taps (the captured ones, plus any a demo run added); `[]` for an engine without taps.
    public func listTaps() async throws -> [String] {
        guard wrapped is any TapListing else { return [] }
        return await inventory.installedTaps()
    }

    /// From the inventory: the installed packages whose captured details list `name` as a dependency (ignoring case).
    /// A package without captured details counts as needing nothing. `[]` for an engine that can't list dependents.
    /// The demo has no captured dependents output, so asking the real engine would fail every uninstall's check.
    public func installedDependents(of name: String) async throws -> Set<String> {
        guard wrapped is any DependentsListing else { return [] }
        let target = name.lowercased()
        var found: Set<String> = []
        for package in await inventory.installed(id) {
            let needs = (try? await wrapped.info(package.id))?.dependencies ?? []
            if needs.contains(where: { $0.lowercased() == target }) { found.insert(package.id.name) }
        }
        return found
    }

    /// The captured details when there are some, otherwise the row's own fields. The installed version always
    /// follows the inventory, so details agree with the lists after a demo run.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        var details: PackageDetails
        do {
            details = try await wrapped.info(ref)
        } catch FixtureRunnerError.unmapped, FixtureRunnerError.unmappedURL {
            guard let row = await inventory.package(ref) else {
                throw EngineError(engine: ref.engine, message: "Demo mode has no details for \(ref.name)")
            }
            details = PackageDetails(ref: ref, summary: row.summary, installedVersion: row.installedVersion,
                                     latestVersion: row.latestVersion ?? row.installedVersion)
        }
        details.installedVersion = await inventory.installedVersion(ref)
        return details
    }

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        wrapped.privilege(for: op, ref)
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        try wrapped.command(for: op, refs, options: options)
    }

    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? {
        wrapped.maxTargetsPerCommand(for: operation)
    }

    /// The real engine's catalogue refresh, so a demo MacPorts update run shows the step BrewxPort would run (the demo
    /// executor only simulates it). Throws for an engine without one.
    public func selfupdateCommand() throws -> CommandSpec {
        guard let refreshing = wrapped as? any CatalogRefreshing else {
            throw EngineError(engine: id, message: "\(id.displayName) has no catalogue to refresh")
        }
        return try refreshing.selfupdateCommand()
    }
}
