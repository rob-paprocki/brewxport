import Foundation

/// Homebrew (formulae and casks), driven through `brew` and its `--json=v2` output.
public struct HomebrewEngine: Engine, TapListing, DependentsListing {
    public let id: EngineID = .homebrew
    public let capabilities: EngineCapabilities = [.casks, .jsonOutput]

    private let runner: CommandRunning
    private let cache: ExecutableCache
    private var executable: URL? { cache.current }
    private let host: Arch

    /// `arch` is the machine's architecture; tests force it.
    public init(runner: CommandRunning, executable: URL?, arch: Arch = .current) {
        self.runner = runner
        self.cache = ExecutableCache(locate: { executable })
        self.host = arch
    }

    public init(runner: CommandRunning, locate: @escaping @Sendable () -> URL?, arch: Arch = .current) {
        self.runner = runner
        self.cache = ExecutableCache(locate: locate)
        self.host = arch
    }

    public var executableURL: URL? { executable }

    /// Intel Homebrew in /usr/local needs Rosetta when the machine is arm64.
    private func arch(for exe: URL?) -> Arch? {
        exe?.path == "/usr/local/bin/brew" ? .x86_64 : nil
    }

    /// x86_64 for Intel Homebrew in /usr/local, otherwise the machine's architecture.
    public var runArch: Arch { arch(for: executable) ?? host }

    /// Every query goes through here so it gets the same arch wrapping as install/upgrade/remove.
    private func query(_ exe: URL, _ args: [String], options: RunOptions = RunOptions()) async throws -> CommandResult {
        let launch = CommandSpec(executable: exe, arguments: args, needsRoot: false, arch: arch(for: exe))
            .launchCommand(host: host)
        return try await runner.run(launch.executable, launch.arguments, options: options)
    }

    // MARK: detect

    public func detect() async -> EngineStatus {
        let exe = cache.relocate()
        return await detectStatus(runner: runner, executable: exe, arguments: ["--version"],
                           arch: arch(for: exe), host: host) { stdout in
            // "Homebrew 7.0.13", or from the official .pkg without a git checkout
            // "Homebrew >=4.3.0 (shallow or no git repository)": any version token after "Homebrew" works.
            guard let first = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "Homebrew" else { return nil }
            let version = parts[1]
            let digits = version.drop(while: { $0 == ">" || $0 == "=" })
            guard digits.first?.isNumber == true else { return nil }
            return String(version)
        }
    }

    // MARK: search

    public func search(_ query: String) async throws -> [Package] {
        let exe = try requireExecutable()
        let formulaArgs = try searchArguments(["search", "--formula"], query: query, engine: .homebrew)
        let caskArgs = try searchArguments(["search", "--cask"], query: query, engine: .homebrew)
        let formulae = try await runSearch(exe, formulaArgs, kind: .formula)
        let casks = try await runSearch(exe, caskArgs, kind: .cask)
        return formulae + casks
    }

    private static let noMatchPrefix = "Error: No formulae or casks found for"

    private func runSearch(_ exe: URL, _ args: [String], kind: PackageKind) async throws -> [Package] {
        let result = try await query(exe, args)
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode != 0 {
            // brew exits 1 for "no match" and for real errors (a bad regex, say); only the first is an empty result.
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 1, out.isEmpty, err.isEmpty || err.hasPrefix(Self.noMatchPrefix) { return [] }
            throw failure("brew \(args.joined(separator: " ")) failed", result)
        }
        return out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { name in
                Package(id: PackageRef(engine: .homebrew, kind: kind, name: name), displayName: name)
            }
    }

    // MARK: installed

    private struct InstalledDoc: Decodable {
        struct Formula: Decodable {
            struct Installed: Decodable {
                let version: String
                /// From the install receipt; missing on receipts older Homebrew versions wrote.
                let installed_on_request: Bool?
            }
            let name: String
            let full_name: String?
            let tap: String?
            let installed: [Installed]
        }
        struct Cask: Decodable {
            let token: String
            let full_token: String?
            let tap: String?
            let installed: String?
        }
        let formulae: [Formula]
        let casks: [Cask]
    }

    /// `qualified` when `tap` is a third-party tap, else nil. Homebrew's own taps (`BundleRules.builtInTaps`) install
    /// by bare name, so their packages never get a `fullName`.
    private static func fullName(_ qualified: String?, tap: String?) -> String? {
        guard let tap = nonBlank(tap), !BundleRules.builtInTaps.contains(tap.lowercased()) else { return nil }
        return nonBlank(qualified)
    }

    public func listInstalled() async throws -> [Package] {
        let doc: InstalledDoc = try await runJSON(["info", "--json=v2", "--installed"])
        let formulae = doc.formulae.map { f in
            Package(id: PackageRef(engine: .homebrew, kind: .formula, name: f.name),
                    displayName: f.name,
                    installedVersion: f.installed.last?.version,
                    fullName: Self.fullName(f.full_name, tap: f.tap),
                    installedOnRequest: f.installed.last?.installed_on_request)
        }
        let casks = doc.casks.map { c in
            Package(id: PackageRef(engine: .homebrew, kind: .cask, name: c.token),
                    displayName: c.token,
                    installedVersion: c.installed,
                    fullName: Self.fullName(c.full_token, tap: c.tap),
                    // Casks are never installed as another package's dependency in practice; count them as asked for.
                    installedOnRequest: true)
        }
        return formulae + casks
    }

    // MARK: taps

    /// Third-party taps from `brew tap`, one per line. `homebrew/core` and `homebrew/cask` are skipped; any other
    /// line that isn't a valid `user/repo` tap name makes the call throw rather than be dropped.
    public func listTaps() async throws -> [String] {
        let exe = try requireExecutable()
        let args = ["tap"]
        let result = try await query(exe, args, options: RunOptions(timeout: BrewxPortTimeouts.engineQuery))
        guard result.exitCode == 0 else { throw failure("brew tap failed", result) }
        var taps: [String] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || BundleRules.builtInTaps.contains(name.lowercased()) { continue }
            guard BundleRules.isValidTapName(name) else {
                throw EngineError(engine: .homebrew,
                                  message: "Couldn't read brew tap output: “\(BundleRules.shown(name))” isn't a tap name")
            }
            taps.append(name)
        }
        return taps
    }

    /// Installed formulae that directly depend on `name`: `brew uses --installed <name>`, one name per line, nothing
    /// when there are none. An unknown name is a warning on stderr with exit 0, so it reads as no dependents.
    public func installedDependents(of name: String) async throws -> Set<String> {
        let name = try packageNameArguments([PackageRef(engine: .homebrew, kind: .formula, name: name)],
                                            engine: .homebrew)[0]
        let exe = try requireExecutable()
        let args = ["uses", "--installed", name]
        let result = try await query(exe, args, options: RunOptions(timeout: BrewxPortTimeouts.engineQuery))
        guard result.exitCode == 0 else { throw failure("brew \(args.joined(separator: " ")) failed", result) }
        return Set(result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    // MARK: outdated

    /// `installed_versions` is an array for formulae; casks may report an array or a single string.
    private struct VersionList: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let many = try? c.decode([String].self) {
                values = many
            } else {
                values = [try c.decode(String.self)]
            }
        }
    }

    private struct OutdatedDoc: Decodable {
        struct Entry: Decodable {
            let name: String
            let installed_versions: VersionList?
            let current_version: String?
        }
        let formulae: [Entry]
        let casks: [Entry]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formulae = try c.decodeIfPresent([Entry].self, forKey: .formulae) ?? []
            casks = try c.decodeIfPresent([Entry].self, forKey: .casks) ?? []
        }
        enum CodingKeys: String, CodingKey { case formulae, casks }
    }

    public func listOutdated() async throws -> [Package] {
        let doc: OutdatedDoc = try await runJSON(["outdated", "--json=v2"])
        func make(_ e: OutdatedDoc.Entry, _ kind: PackageKind) -> Package {
            Package(id: PackageRef(engine: .homebrew, kind: kind, name: e.name),
                    displayName: e.name,
                    installedVersion: e.installed_versions?.values.last,
                    latestVersion: e.current_version)
        }
        return doc.formulae.map { make($0, .formula) } + doc.casks.map { make($0, .cask) }
    }

    // MARK: info

    /// Only the keys of one artifact entry matter: `pkg` and `installer` mean a root installer.
    private struct ArtifactKeys: Decodable {
        let keys: Set<String>
        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        init(from decoder: Decoder) throws {
            keys = Set(try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue))
        }
    }

    private struct InfoDoc: Decodable {
        struct Formula: Decodable {
            struct Installed: Decodable { let version: String }
            struct Versions: Decodable { let stable: String? }
            let name: String
            let full_name: String?
            let desc: String?
            let homepage: String?
            let versions: Versions?
            let installed: [Installed]?
            let dependencies: [String]?
        }
        struct Cask: Decodable {
            let token: String
            let full_token: String?
            let desc: String?
            let homepage: String?
            let version: String?
            let installed: String?
            let artifacts: [ArtifactKeys]?
            /// `formula` lists the formulae the cask needs; other keys (`macos`, `cask`, `arch`) aren't packages.
            struct DependsOn: Decodable { let formula: [String]? }
            let depends_on: DependsOn?
        }
        let formulae: [Formula]?
        let casks: [Cask]?
    }

    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .homebrew else {
            throw EngineError(engine: .homebrew, message: "Package belongs to a different engine")
        }
        let flag: String
        switch ref.kind {
        case .formula: flag = "--formula"
        case .cask: flag = "--cask"
        default: throw EngineError(engine: .homebrew, message: "Homebrew has no \(ref.kind.rawValue) packages")
        }
        let name = try packageNameArguments([ref], engine: .homebrew)[0]
        let doc: InfoDoc = try await runJSON(["info", "--json=v2", flag, name])
        let none = EngineError(engine: .homebrew, message: "brew had no information for \(name)")
        if ref.kind == .cask {
            let casks = doc.casks ?? []
            guard let c = casks.first(where: { $0.token == name || $0.full_token == name })
                    ?? (casks.count == 1 ? casks[0] : nil) else { throw none }
            return PackageDetails(
                ref: ref, summary: nonBlank(c.desc), homepage: webURL(c.homepage),
                installedVersion: nonBlank(c.installed), latestVersion: nonBlank(c.version),
                dependencies: c.depends_on.map { $0.formula ?? [] },
                installerNeedsRoot: c.artifacts.map { list in
                    list.contains { !$0.keys.isDisjoint(with: ["pkg", "installer"]) }
                }, reportedName: c.token)
        }
        let formulae = doc.formulae ?? []
        guard let f = formulae.first(where: { $0.name == name || $0.full_name == name })
                ?? (formulae.count == 1 ? formulae[0] : nil) else { throw none }
        return PackageDetails(
            ref: ref, summary: nonBlank(f.desc), homepage: webURL(f.homepage),
            installedVersion: f.installed?.last?.version, latestVersion: nonBlank(f.versions?.stable),
            dependencies: f.dependencies, reportedName: f.name)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        if op == .markRequested || op == .markDependency { return .never }
        return ref.kind == .cask ? .sometimes : .never
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard let first = refs.first else {
            throw EngineError(engine: .homebrew, message: "No packages given")
        }
        guard refs.allSatisfy({ $0.engine == .homebrew }) else {
            throw EngineError(engine: .homebrew, message: "Package belongs to a different engine")
        }
        if op == .markRequested || op == .markDependency {
            return try markCommand(for: op, refs, options: options)
        }
        // Taps first, before the formula/cask check: a tap is added with `brew tap`, one per command, never installed.
        if refs.contains(where: { $0.kind == .tap }) {
            return try tapCommand(for: op, refs, options: options)
        }
        guard refs.allSatisfy({ $0.kind == first.kind }) else {
            throw EngineError(engine: .homebrew, message: "Formulae and casks must be handled in separate commands")
        }
        guard options.version == nil else {
            throw EngineError(engine: .homebrew, message: "Homebrew can't install a specific version")
        }
        guard options.variants.isEmpty else {
            throw EngineError(engine: .homebrew, message: "Homebrew has no variants")
        }
        let names = try packageNameArguments(refs, engine: .homebrew)
        let exe = try requireExecutable()
        let verb: String
        switch op {
        case .install: verb = "install"
        case .upgrade: verb = "upgrade"
        case .remove: verb = "uninstall"
        case .markRequested, .markDependency: preconditionFailure("handled by markCommand")
        }
        var args = [verb]
        if first.kind == .cask {
            args.append("--cask")
        } else if (op == .install || op == .remove), first.kind == .formula {
            // A formula entry named like a cask must not install the cask. For a removal it matters more:
            // with the formula already gone, a bare `uninstall foo` removes an installed cask `foo` and exits 0.
            args.append("--formula")
        }
        args += options.extraArgs
        args += names
        return CommandSpec(executable: exe, arguments: args, needsRoot: false, arch: arch(for: exe))
    }

    /// `brew tab --installed-on-request <formula>` or `--no-installed-on-request`: flips the flag Homebrew keeps
    /// for "asked for" versus "installed as a dependency". Formulae only, no options, never root.
    private func markCommand(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws
        -> CommandSpec {
        guard refs.allSatisfy({ $0.kind == .formula }) else {
            throw EngineError(engine: .homebrew, message: "Homebrew can only mark formulae")
        }
        guard options == InstallOptions() else {
            throw EngineError(engine: .homebrew, message: "Marking a package takes no options")
        }
        let names = try packageNameArguments(refs, engine: .homebrew)
        let exe = try requireExecutable()
        let flag = op == .markRequested ? "--installed-on-request" : "--no-installed-on-request"
        return CommandSpec(executable: exe, arguments: ["tab", flag] + names, needsRoot: false, arch: arch(for: exe))
    }

    /// `brew tap <user/repo>`: exactly one third-party tap, install only, no options.
    private func tapCommand(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws
        -> CommandSpec {
        guard refs.allSatisfy({ $0.kind == .tap }) else {
            throw EngineError(engine: .homebrew, message: "Taps must be added in their own command")
        }
        guard refs.count == 1, let tap = refs.first else {
            throw EngineError(engine: .homebrew, message: "Taps are added one at a time")
        }
        guard op == .install else {
            throw EngineError(engine: .homebrew, message: "BrewxPort only adds taps")
        }
        guard options == InstallOptions() else {
            throw EngineError(engine: .homebrew, message: "Adding a tap takes no options")
        }
        let names = try packageNameArguments(refs, engine: .homebrew)
        guard BundleRules.isValidTapName(tap.name) else {
            throw EngineError(engine: .homebrew, message: "Invalid tap name: \(BundleRules.shown(tap.name))")
        }
        let exe = try requireExecutable()
        return CommandSpec(executable: exe, arguments: ["tap"] + names, needsRoot: false, arch: arch(for: exe))
    }

    // MARK: helpers

    private func requireExecutable() throws -> URL {
        guard let executable else {
            throw EngineError(engine: .homebrew, message: "Homebrew isn't installed")
        }
        return executable
    }

    private func runJSON<T: Decodable>(_ args: [String]) async throws -> T {
        let exe = try requireExecutable()
        let result = try await query(exe, args)
        guard result.exitCode == 0 else {
            throw failure("brew \(args.joined(separator: " ")) failed", result)
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(result.stdout.utf8))
        } catch {
            throw EngineError(engine: .homebrew, message: "Couldn't read brew's JSON output: \(error.localizedDescription)")
        }
    }

    private func failure(_ what: String, _ result: CommandResult) -> EngineError {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(err.prefix(300))
        let suffix = excerpt.isEmpty ? "" : ": \(excerpt)"
        return EngineError(engine: .homebrew, message: "\(what) (exit \(result.exitCode))\(suffix)")
    }
}
