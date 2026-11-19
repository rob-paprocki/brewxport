import Foundation

/// Homebrew (formulae and casks), driven through `brew` and its `--json=v2` output.
public struct HomebrewEngine: Engine {
    public let id: EngineID = .homebrew
    public let capabilities: EngineCapabilities = [.casks, .jsonOutput]

    private let runner: CommandRunning
    private let executable: URL?
    private let host: Arch

    /// `arch` is the machine's architecture; tests force it.
    public init(runner: CommandRunning, executable: URL?, arch: Arch = .current) {
        self.runner = runner
        self.executable = executable
        self.host = arch
    }

    public var executableURL: URL? { executable }

    /// Intel Homebrew in /usr/local needs Rosetta when the machine is arm64.
    private var commandArch: Arch? {
        executable?.path == "/usr/local/bin/brew" ? .x86_64 : nil
    }

    /// x86_64 for Intel Homebrew in /usr/local, otherwise the machine's architecture.
    public var runArch: Arch { commandArch ?? host }

    /// Every query goes through here so it gets the same arch wrapping as install/upgrade/remove.
    private func query(_ exe: URL, _ args: [String]) async throws -> CommandResult {
        let launch = CommandSpec(executable: exe, arguments: args, needsRoot: false, arch: commandArch)
            .launchCommand(host: host)
        return try await runner.run(launch.executable, launch.arguments)
    }

    // MARK: detect

    public func detect() async -> EngineStatus {
        await detectStatus(runner: runner, executable: executable, arguments: ["--version"],
                           arch: commandArch, host: host) { stdout in
            // "Homebrew 7.0.13"
            guard let first = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "Homebrew", parts[1].first?.isNumber == true else { return nil }
            return String(parts[1])
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
            struct Installed: Decodable { let version: String }
            let name: String
            let installed: [Installed]
        }
        struct Cask: Decodable {
            let token: String
            let installed: String?
        }
        let formulae: [Formula]
        let casks: [Cask]
    }

    public func listInstalled() async throws -> [Package] {
        let doc: InstalledDoc = try await runJSON(["info", "--json=v2", "--installed"])
        let formulae = doc.formulae.map { f in
            Package(id: PackageRef(engine: .homebrew, kind: .formula, name: f.name),
                    displayName: f.name,
                    installedVersion: f.installed.last?.version)
        }
        let casks = doc.casks.map { c in
            Package(id: PackageRef(engine: .homebrew, kind: .cask, name: c.token),
                    displayName: c.token,
                    installedVersion: c.installed)
        }
        return formulae + casks
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
                installerNeedsRoot: c.artifacts.map { list in
                    list.contains { !$0.keys.isDisjoint(with: ["pkg", "installer"]) }
                })
        }
        let formulae = doc.formulae ?? []
        guard let f = formulae.first(where: { $0.name == name || $0.full_name == name })
                ?? (formulae.count == 1 ? formulae[0] : nil) else { throw none }
        return PackageDetails(
            ref: ref, summary: nonBlank(f.desc), homepage: webURL(f.homepage),
            installedVersion: f.installed?.last?.version, latestVersion: nonBlank(f.versions?.stable),
            dependencies: f.dependencies)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        ref.kind == .cask ? .sometimes : .never
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard let first = refs.first else {
            throw EngineError(engine: .homebrew, message: "No packages given")
        }
        guard refs.allSatisfy({ $0.engine == .homebrew }) else {
            throw EngineError(engine: .homebrew, message: "Package belongs to a different engine")
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
        }
        var args = [verb]
        if first.kind == .cask { args.append("--cask") }
        args += options.extraArgs
        args += names
        return CommandSpec(executable: exe, arguments: args, needsRoot: false, arch: commandArch)
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
