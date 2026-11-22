import Foundation
import BrewxPortCore
import BrewxPortRun

/// One package the user asked to install, update or remove.
public struct ActionRequest: Sendable, Equatable {
    public let operation: PackageOperation
    public let package: Package
    public let options: InstallOptions

    public init(operation: PackageOperation, package: Package, options: InstallOptions = InstallOptions()) {
        self.operation = operation
        self.package = package
        self.options = options
    }
}

/// The steps of one run, plus what couldn't be planned (`problems`) and what the user should know (`notes`).
public struct ActionPlan: Sendable, Equatable {
    public let steps: [RunStep]
    public let problems: [String]
    public let notes: [String]
    /// What the password prompt says the password is for.
    public let reason: String

    public init(steps: [RunStep], problems: [String], notes: [String], reason: String) {
        self.steps = steps
        self.problems = problems
        self.notes = notes
        self.reason = reason
    }
}

/// Turns requests into run steps.
///
/// Removes run first, then installs, then upgrades. Within each, engines go in `order`, and within an engine,
/// Homebrew taps come first (so formulae from them resolve), then formulae (or ports, or apps), then casks, because
/// Homebrew and nanobrew can't mix the two in one command. Requests are batched into one step per (operation, engine,
/// kind group); every tap, and every request with non-default `InstallOptions`, gets a step of its own, so a MacPorts
/// install with variants is always one port. Two installs share a name when `BundleRules.duplicateKey` matches.
///
/// Each step's command comes from the engine's own `command(for:…)`. An engine that can't build its command is
/// reported in `problems` and left out; the other steps still run.
public enum ActionPlanner {
    private struct Item {
        let operation: PackageOperation
        let ref: PackageRef
        let name: String
        let options: InstallOptions
    }

    private static let phases: [PackageOperation] = [.remove, .install, .upgrade]

    public static func make(_ requests: [ActionRequest], engines: [any Engine], order: [EngineID],
                            caskRoutes: [PackageRef: CaskRoute] = [:]) -> ActionPlan {
        var problems: [String] = []
        var notes: [String] = []
        func position(_ id: EngineID) -> Int { order.firstIndex(of: id) ?? order.count }
        func byPosition(_ a: EngineID, _ b: EngineID) -> Bool {
            (position(a), a.rawValue) < (position(b), b.rawValue)
        }

        // The same request twice (a double click on a row) counts once.
        var unique: [ActionRequest] = []
        for request in requests where !unique.contains(request) { unique.append(request) }

        // The same name installed from two engines, or twice as the same kind from one (Homebrew's formulae `jq` and
        // `foo/bar/jq`): the user has to pick one. A formula and a cask with one name install side by side.
        var refusedInstalls = Set<PackageRef>()
        var installNames: [String] = []
        var installsByName: [String: [ActionRequest]] = [:]
        for request in unique where request.operation == .install {
            let key = BundleRules.duplicateKey(request.package) // the import preview's key too
            if installsByName[key] == nil { installNames.append(key) }
            installsByName[key, default: []].append(request)
        }
        for key in installNames {
            let group = installsByName[key] ?? []
            let sources = Set(group.map(\.package.id.engine)).sorted(by: byPosition)
            if sources.count > 1 {
                problems.append("\(group[0].package.displayName) is selected from "
                                + "\(listed(sources.map(\.displayName))). Pick one.")
                refusedInstalls.formUnion(group.map(\.package.id))
                continue
            }
            // One engine: refuse only refs that share a kind with another.
            var kinds: [PackageKind] = []
            var refsByKind: [PackageKind: [PackageRef]] = [:]
            for request in group {
                let ref = request.package.id
                if refsByKind[ref.kind] == nil { kinds.append(ref.kind) }
                if !(refsByKind[ref.kind] ?? []).contains(ref) { refsByKind[ref.kind, default: []].append(ref) }
            }
            for kind in kinds {
                let refs = refsByKind[kind] ?? []
                guard refs.count > 1 else { continue }
                problems.append("\(group[0].package.displayName) is selected twice from \(sources[0].displayName) "
                                + "(\(listed(refs.map(\.name)))). Pick one.")
                refusedInstalls.formUnion(refs)
            }
        }

        // nanobrew cask installs whose installer needs root go to Homebrew, or can't be done.
        var items: [Item] = []
        for request in unique {
            var ref = request.package.id
            let name = request.package.displayName
            if request.operation == .install {
                if refusedInstalls.contains(ref) { continue }
                if ref.engine == .nanobrew, ref.kind == .cask {
                    switch caskRoutes[ref] ?? .nanobrew {
                    case .nanobrew:
                        break
                    case .homebrew:
                        ref = PackageRef(engine: .homebrew, kind: .cask, name: ref.name)
                        notes.append("\(name): installed with Homebrew, because its installer needs administrator "
                                     + "rights and nanobrew can't use them.")
                    case .needsHomebrew:
                        problems.append(CaskRouting.needsHomebrewText(name: name))
                        continue
                    }
                }
            }
            items.append(Item(operation: request.operation, ref: ref, name: name, options: request.options))
        }

        var steps: [RunStep] = []
        let sortedEngines = engines.sorted { byPosition($0.id, $1.id) }
        for operation in phases {
            for engine in sortedEngines {
                let mine = items.filter { $0.operation == operation && $0.ref.engine == engine.id }
                let taps = mine.filter { $0.ref.kind == .tap }
                let packages = mine.filter { $0.ref.kind != .tap && $0.ref.kind != .cask }
                let casks = mine.filter { $0.ref.kind == .cask }
                // Taps first, so formulae from them resolve; `brew tap` takes one tap per command.
                for batch in taps.map({ [$0] }) + batches(packages) + batches(casks) {
                    let refs = batch.map(\.ref)
                    let kind = refs[0].kind
                    let stepTitle = kind == .tap && operation == .install ? "Add tap `\(refs[0].name)`"
                        : Self.title(engine.id, kind: kind, names: batch.map(\.name))
                    do {
                        let spec = try engine.command(for: operation, refs, options: batch[0].options)
                        steps.append(RunStep(engine: engine.id, kind: kind, operation: operation, spec: spec,
                                             title: stepTitle))
                    } catch let error as EngineError {
                        problems.append("\(stepTitle): \(error.message)")
                    } catch {
                        problems.append("\(stepTitle): \(error)")
                    }
                }
            }
        }

        let known = Set(engines.map(\.id))
        for id in Set(items.map(\.ref.engine)).subtracting(known).sorted(by: byPosition) {
            problems.append("\(id.displayName) isn't available, so its packages were left out.")
        }

        let operations = Set(steps.isEmpty ? unique.map(\.operation) : steps.map(\.operation))
        return ActionPlan(steps: steps, problems: problems, notes: notes, reason: reason(for: operations))
    }

    /// Requests with default options share one step; each request with its own options gets its own.
    private static func batches(_ items: [Item]) -> [[Item]] {
        let plain = items.filter { $0.options == InstallOptions() }
        let custom = items.filter { $0.options != InstallOptions() }
        return (plain.isEmpty ? [] : [plain]) + custom.map { [$0] }
    }

    static func title(_ engine: EngineID, kind: PackageKind, names: [String]) -> String {
        let what = kind == .cask ? "\(engine.displayName) casks" : engine.displayName
        return "\(what): \(names.joined(separator: ", "))"
    }

    static func reason(for operations: Set<PackageOperation>) -> String {
        let what: String
        if operations.count == 1, let only = operations.first {
            switch only {
            case .install: what = "install these packages"
            case .upgrade: what = "update these packages"
            case .remove: what = "remove these packages"
            }
        } else {
            what = "make these changes"
        }
        return "BrewxPort needs an administrator password to \(what)."
    }

    /// "A and B", "A, B and C".
    private static func listed(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
