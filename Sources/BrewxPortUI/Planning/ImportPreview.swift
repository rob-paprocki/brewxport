import Foundation
import BrewxPortCore

/// A file to import: a `.brewxportbundle` or a Brewfile, already read and checked by `BundleRules`.
public enum ImportSource: Equatable, Sendable {
    case bundle(BundleFile)
    case brewfile(BrewfileDocument)
}

/// What's on this Mac, from loaded engine lists. `taps` is `HomebrewEngine.listTaps()`.
public struct InstalledState: Equatable, Sendable {
    public var packages: [Package]
    public var taps: [String]

    public init(packages: [Package], taps: [String]) {
        self.packages = packages
        self.taps = taps
    }
}

public enum ImportRowState: Hashable, Sendable {
    /// Can be installed.
    case willInstall
    /// Already on this Mac (matched by `BundleRules.matchKey`), with that package's installed version.
    case alreadyInstalled(version: String?)
    /// The row's engine is missing or not working. Never requested.
    case engineMissing
    /// Another installable row in the same file has the same `BundleRules.duplicateKey`: from another engine, or from
    /// the same one (Homebrew's `jq` and `foo/bar/jq`). `of` is the first other engine in `order` with such a row, or
    /// the row's own engine when every copy is from it. Installable, but only one copy starts checked: the one from
    /// the engine earliest in `order`, and within an engine the first in the file.
    case duplicate(of: EngineID)
}

/// One entry of the file, as the preview shows it.
public struct ImportRow: Identifiable, Hashable, Sendable {
    public var id: PackageRef
    /// Display-safe text from the file model. For a mas app, the app name with its id next to it:
    /// "Refined GitHub (1519867270)".
    public var displayName: String
    public var state: ImportRowState
    /// A version pin from a bundle: shown, never applied.
    public var pin: String?
    /// The file's install options, `version` always nil.
    public var options: InstallOptions
    public var notes: [String]
    /// The name a request carries: `displayName` without the mas id. `BundleRules.duplicateKey` and the planner's
    /// step titles read it.
    var packageName: String

    init(id: PackageRef, displayName: String, packageName: String, state: ImportRowState, pin: String?,
         options: InstallOptions, notes: [String]) {
        self.id = id
        self.displayName = displayName
        self.packageName = packageName
        self.state = state
        self.pin = pin
        self.options = options
        self.notes = notes
    }

    var isInstallable: Bool { state.isInstallable }
}

public struct EngineGroup: Equatable, Sendable {
    public var engine: EngineID
    public var rows: [ImportRow]

    public init(engine: EngineID, rows: [ImportRow]) {
        self.engine = engine
        self.rows = rows
    }
}

/// One entry or line BrewxPort doesn't handle, ready to show. All three strings are display-safe as they come from
/// the readers; nothing here re-reads the file.
public struct PreviewUnhandled: Equatable, Sendable {
    /// "line 12" for a Brewfile (1-based), "entry 3" for a bundle (`UnhandledEntry.index + 1`).
    public var location: String
    /// The Brewfile line, or the bundle entry's JSON.
    public var text: String
    public var reason: String

    public init(location: String, text: String, reason: String) {
        self.location = location
        self.text = text
        self.reason = reason
    }
}

/// What importing a file would do: rows grouped by engine with their state, engines that need setting up, and
/// everything the file holds that BrewxPort won't install, with reasons. Pure: built from loaded state, no I/O.
///
/// "Installed" uses `BundleRules.matchKey`: engine, kind and the last name segment, case-folded. Homebrew lists
/// installed formulae by bare name, so `felixkratz/formulae/borders` in a file matches an installed `borders`.
/// The cost: a formula from one tap matches a same-named formula from another (`foo/bar/jq` shows as installed when
/// core `jq` is), and is then neither checked nor requested. Taps match `installed.taps` case-insensitively.
public struct ImportPreview: Equatable, Sendable {
    public static let tapNote = "Adds a third-party source of packages"
    /// On a tap row that starts unchecked because nothing checked in the file is named with its prefix. A Brewfile
    /// can list a tap's packages by bare name, so the tap may still be needed; the user decides.
    public static let standaloneTapHint = "Packages listed without a tap prefix may need this tap"

    /// On a row that starts unchecked because another engine already has a package with this name installed.
    public static func alreadyWithNote(_ engine: EngineID) -> String {
        "Already installed with \(engine.displayName)"
    }

    public static func pinNote(_ pin: String) -> String {
        "Pinned to \(pin) in the file, but BrewxPort installs the latest version"
    }

    /// How a Brewfile's lines were accounted for. Every line is an entry, a line BrewxPort doesn't handle, or a blank
    /// or comment line counted in `ignored`.
    public struct BrewfileLines: Equatable, Sendable {
        /// Lines in the file.
        public var total: Int
        /// Blank and whole-comment lines.
        public var ignored: Int

        public init(total: Int, ignored: Int) {
            self.total = total
            self.ignored = ignored
        }
    }

    /// Engines in `order` (any not in it after, by name); within Homebrew, taps first, then file order.
    public var groups: [EngineGroup]
    /// Engines with rows in the file that are missing or unusable, in group order.
    public var missingEngines: [EngineSetup]
    /// In file order.
    public var unhandled: [PreviewUnhandled]
    public var initiallyChecked: Set<PackageRef>
    /// A Brewfile's line counts; nil for a bundle.
    public var brewfileLines: BrewfileLines?

    public init(groups: [EngineGroup], missingEngines: [EngineSetup], unhandled: [PreviewUnhandled],
                initiallyChecked: Set<PackageRef>, brewfileLines: BrewfileLines? = nil) {
        self.groups = groups
        self.missingEngines = missingEngines
        self.unhandled = unhandled
        self.initiallyChecked = initiallyChecked
        self.brewfileLines = brewfileLines
    }

    private var rows: [ImportRow] { groups.flatMap(\.rows) }

    /// "3 lines BrewxPort doesn't handle" for a Brewfile, "1 entry BrewxPort doesn't handle" for a bundle.
    public var unhandledTitle: String {
        let count = unhandled.count
        let noun = brewfileLines != nil ? (count == 1 ? "line" : "lines") : (count == 1 ? "entry" : "entries")
        return "\(count) \(noun) BrewxPort doesn't handle"
    }

    /// "9 blank or comment lines" for a Brewfile; nil for a bundle.
    public var ignoredLinesText: String? {
        guard let lines = brewfileLines else { return nil }
        return lines.ignored == 1 ? "1 blank or comment line" : "\(lines.ignored) blank or comment lines"
    }

    /// Rows that can be installed: `willInstall` and `duplicate`.
    public var toInstallCount: Int { rows.filter(\.isInstallable).count }
    /// Rows already on this Mac.
    public var installedCount: Int { rows.filter(\.state.isAlreadyInstalled).count }
    /// Rows skipped because their engine is missing or unusable, plus unhandled entries or lines. Blank and comment
    /// lines of a Brewfile aren't counted.
    public var skippedCount: Int { rows.filter { $0.state == .engineMissing }.count + unhandled.count }

    /// Install requests for the checked rows that can be installed, in group order. `alreadyInstalled` and
    /// `engineMissing` rows are never requested, even when checked; `options.version` is always nil.
    public func requests(for checked: Set<PackageRef>) -> [ActionRequest] {
        rows.filter { $0.isInstallable && checked.contains($0.id) }.map { row in
            ActionRequest(
                operation: .install,
                package: Package(id: row.id, displayName: row.packageName),
                options: InstallOptions(version: nil, variants: row.options.variants, extraArgs: row.options.extraArgs)
            )
        }
    }

    private struct Candidate {
        let ref: PackageRef
        let name: String
        let pin: String?
        let options: InstallOptions
        /// For "listed twice": where the entry is and its text.
        let location: String
        let text: String
    }

    /// Builds the preview. An engine absent from `status` counts as missing.
    public static func make(_ source: ImportSource, installed: InstalledState, status: [EngineID: EngineStatus],
                            order: [EngineID]) -> ImportPreview {
        var candidates: [Candidate] = []
        var unhandled: [PreviewUnhandled] = []
        var brewfileLines: BrewfileLines?
        switch source {
        case .bundle(let file):
            candidates = file.entries.map {
                Candidate(ref: $0.ref, name: $0.displayName, pin: $0.versionPin,
                          options: InstallOptions(version: nil, variants: $0.options.variants,
                                                  extraArgs: $0.options.extraArgs),
                          location: "entry", text: $0.displayName)
            }
            unhandled = file.unhandled.map {
                PreviewUnhandled(location: "entry \($0.index + 1)", text: $0.json, reason: $0.reason)
            }
        case .brewfile(let document):
            candidates = document.entries.map {
                Candidate(ref: $0.ref, name: $0.displayName, pin: nil, options: InstallOptions(),
                          location: "line \($0.line)", text: $0.displayName)
            }
            unhandled = document.unhandled.map {
                PreviewUnhandled(location: "line \($0.line)", text: $0.text, reason: $0.reason)
            }
            brewfileLines = BrewfileLines(total: document.lineCount, ignored: document.ignoredCount)
        }

        // One row per ref, so rows are keyed uniquely. Decoded files never repeat a ref (both readers keep the
        // second as "listed twice"); a source built in code can, and the repeat is shown the same way.
        var seenRefs = Set<PackageRef>()
        var repeats: [PreviewUnhandled] = []
        candidates = candidates.filter { c in
            if seenRefs.insert(c.ref).inserted { return true }
            repeats.append(PreviewUnhandled(location: c.location, text: c.text, reason: "listed twice"))
            return false
        }
        unhandled += repeats

        func position(_ id: EngineID) -> Int { order.firstIndex(of: id) ?? order.count }
        func byPosition(_ a: EngineID, _ b: EngineID) -> Bool { (position(a), a.rawValue) < (position(b), b.rawValue) }
        func usable(_ id: EngineID) -> Bool {
            if case .present = status[id] { return true }
            return false
        }

        var installedByKey: [String: Package] = [:]
        for package in installed.packages where installedByKey[BundleRules.matchKey(package.id)] == nil {
            installedByKey[BundleRules.matchKey(package.id)] = package
        }
        let installedTaps = Set(installed.taps.map { $0.lowercased() })

        // State before duplicates.
        var states: [ImportRowState] = candidates.map { c in
            if !usable(c.ref.engine) { return .engineMissing }
            if c.ref.kind == .tap {
                return installedTaps.contains(c.ref.name.lowercased()) ? .alreadyInstalled(version: nil) : .willInstall
            }
            if let match = installedByKey[BundleRules.matchKey(c.ref)] {
                return .alreadyInstalled(version: match.installedVersion)
            }
            return .willInstall
        }

        // Duplicates: installable rows with the same key from different engines, or from one engine as the same kind
        // (formulae `jq` and `foo/bar/jq`; a formula and a cask with one name install side by side). Of the rows that
        // clash with each other, one is checked: the earliest engine's, and within it the first in the file.
        var checked = Set<PackageRef>()
        var byKey: [String: [Int]] = [:]
        for (i, c) in candidates.enumerated() where states[i] == .willInstall && c.ref.kind != .tap {
            byKey[BundleRules.duplicateKey(Package(id: c.ref, displayName: c.name)), default: []].append(i)
        }
        for (i, c) in candidates.enumerated() where states[i] == .willInstall && c.ref.kind != .tap {
            let group = byKey[BundleRules.duplicateKey(Package(id: c.ref, displayName: c.name))] ?? [i]
            // The rows this one clashes with, itself included, in file order.
            let clashing = group.filter {
                $0 == i || candidates[$0].ref.engine != c.ref.engine || candidates[$0].ref.kind == c.ref.kind
            }
            guard clashing.count > 1 else {
                checked.insert(c.ref)
                continue
            }
            let engines = Set(clashing.map { candidates[$0].ref.engine }).sorted(by: byPosition)
            states[i] = .duplicate(of: engines.first(where: { $0 != c.ref.engine }) ?? c.ref.engine)
            // `clashing` is in file order, so the first index from the earliest engine is the copy to check.
            if clashing.first(where: { candidates[$0].ref.engine == engines[0] }) == i { checked.insert(c.ref) }
        }

        // A row whose name another engine already has installed starts unchecked, with a note: one more Install
        // would put a second copy on the Mac (Homebrew's figlet installed, the file also lists MacPorts' figlet).
        // It stays installable. The same engine's other kind (formula and cask `docker`) doesn't count.
        var installedElsewhere: [String: [EngineID]] = [:]
        for package in installed.packages where package.id.kind != .tap {
            installedElsewhere[BundleRules.duplicateKey(package), default: []].append(package.id.engine)
        }
        var alreadyWith: [Int: EngineID] = [:]
        for (i, c) in candidates.enumerated() where states[i].isInstallable && c.ref.kind != .tap {
            let others = (installedElsewhere[BundleRules.duplicateKey(Package(id: c.ref, displayName: c.name))] ?? [])
                .filter { $0 != c.ref.engine }.sorted(by: byPosition)
            guard let other = others.first else { continue }
            alreadyWith[i] = other
            checked.remove(c.ref)
        }

        // A tap starts checked only when a checked Homebrew formula or cask is qualified with it.
        let neededTaps = Set(checked.compactMap { ref -> String? in
            guard ref.engine == .homebrew, ref.kind != .tap else { return nil }
            return BundleRules.tapPrefix(ref.name)
        })
        for (i, c) in candidates.enumerated() where c.ref.kind == .tap && states[i] == .willInstall {
            if neededTaps.contains(c.ref.name.lowercased()) { checked.insert(c.ref) }
        }

        let rows: [ImportRow] = candidates.enumerated().map { i, c in
            var notes: [String] = []
            if c.ref.kind == .tap {
                // A tap that's already added brings nothing new.
                if !states[i].isAlreadyInstalled { notes.append(tapNote) }
                if states[i] == .willInstall, !checked.contains(c.ref) { notes.append(standaloneTapHint) }
            } else if c.ref.engine == .homebrew, let tap = BundleRules.tapPrefix(c.ref.name),
                      !BundleRules.builtInTaps.contains(tap), !installedTaps.contains(tap),
                      !states[i].isAlreadyInstalled {
                notes.append(tapNote)
            }
            if let other = alreadyWith[i] { notes.append(alreadyWithNote(other)) }
            // A pin only matters on a row that would be installed.
            if let pin = c.pin, states[i].isInstallable { notes.append(pinNote(pin)) }
            let shown = c.ref.engine == .mas ? "\(c.name) (\(c.ref.name))" : c.name
            return ImportRow(id: c.ref, displayName: shown, packageName: c.name, state: states[i], pin: c.pin,
                             options: c.options, notes: notes)
        }

        var groups: [EngineGroup] = []
        var missing: [EngineSetup] = []
        for engine in Set(rows.map(\.id.engine)).sorted(by: byPosition) {
            let mine = rows.filter { $0.id.engine == engine }
            groups.append(EngineGroup(engine: engine, rows: mine.filter { $0.id.kind == .tap }
                                                            + mine.filter { $0.id.kind != .tap }))
            if !usable(engine), var setup = EngineSetup.setup(for: engine, status: status[engine] ?? .missing) {
                setup.skippedCount = mine.count
                missing.append(setup)
            }
        }
        return ImportPreview(groups: groups, missingEngines: missing, unhandled: unhandled, initiallyChecked: checked,
                             brewfileLines: brewfileLines)
    }
}

extension ImportRowState {
    var isAlreadyInstalled: Bool {
        if case .alreadyInstalled = self { return true }
        return false
    }

    /// `willInstall` or `duplicate`: the states `requests(for:)` turns into requests.
    var isInstallable: Bool {
        switch self {
        case .willInstall, .duplicate: return true
        case .alreadyInstalled, .engineMissing: return false
        }
    }
}
