import Foundation
import BrewxPortCore
import BrewxPortRun

/// What demo mode has "installed": read once from the fixtures, then changed only by `DemoRunExecutor`.
public actor DemoInventory {
    private var installed: [EngineID: [Package]]
    private var outdated: [EngineID: [Package]]
    /// Every row a search has shown, so an install knows the package's name, summary and version.
    private var known: [PackageRef: Package] = [:]

    public init(installed: [EngineID: [Package]], outdated: [EngineID: [Package]]) {
        self.installed = installed
        self.outdated = outdated
    }

    func installed(_ engine: EngineID) -> [Package] { installed[engine] ?? [] }
    func outdated(_ engine: EngineID) -> [Package] { outdated[engine] ?? [] }

    func remember(_ packages: [Package]) {
        for package in packages { known[package.id] = package }
    }

    /// The row for `ref`: outdated first (it has both versions), then installed, then what a search showed.
    func package(_ ref: PackageRef) -> Package? {
        outdated[ref.engine]?.first { $0.id == ref } ?? installed[ref.engine]?.first { $0.id == ref } ?? known[ref]
    }

    /// Nil when the inventory doesn't have `ref` installed.
    func installedVersion(_ ref: PackageRef) -> String? {
        installed[ref.engine]?.first { $0.id == ref }?.installedVersion
    }

    /// What the step would have done. Steps are batched, so the packages are the step's arguments that name one;
    /// anything else (flags, variants) is skipped. This assumes no package is named like a verb or flag the step
    /// also carries ("install", "-N", "--cask"); the captured fixtures have none.
    func apply(_ step: RunStep) {
        let engine = step.engine
        let names = Set(step.spec.arguments)
        switch step.operation {
        case .install:
            var adding = known.values.filter { $0.id.engine == engine && names.contains($0.id.name) }
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
            for var row in adding where !(installed[engine] ?? []).contains(where: { $0.id == row.id }) {
                row.installedVersion = row.latestVersion ?? row.installedVersion
                installed[engine, default: []].append(row)
            }
        case .upgrade:
            let upgraded = (outdated[engine] ?? []).filter { names.contains($0.id.name) }
            outdated[engine]?.removeAll { names.contains($0.id.name) }
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
            outdated[engine]?.removeAll { names.contains($0.id.name) }
        }
    }
}

/// A real engine on a `FixtureRunner`, with its installed and outdated lists kept in a shared `DemoInventory`.
///
/// Searches go through the real engine's parser on the captured search and keep the rows whose name contains the
/// query. Commands and privileges are the real engine's, so the steps a demo run shows are the ones BrewxPort would run.
public final class DemoEngine: Engine {
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

    public func search(_ query: String) async throws -> [Package] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let found = try await wrapped.search(query).filter {
            $0.displayName.lowercased().contains(needle) || $0.id.name.lowercased().contains(needle)
        }
        await inventory.remember(found)
        return found
    }

    public func listInstalled() async throws -> [Package] { await inventory.installed(id) }
    public func listOutdated() async throws -> [Package] { await inventory.outdated(id) }

    /// The captured details when there are some, otherwise the row's own fields. The installed version always
    /// follows the inventory, so details agree with the lists after a demo run.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        var details: PackageDetails
        do {
            details = try await wrapped.info(ref)
        } catch FixtureRunnerError.unmapped {
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
}
