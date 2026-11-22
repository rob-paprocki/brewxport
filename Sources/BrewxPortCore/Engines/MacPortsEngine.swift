import Foundation

/// MacPorts, driven through the `port` command line. Every install, upgrade and remove needs root.
public struct MacPortsEngine: Engine, DependentsListing {
    public let id: EngineID = .macports
    public let capabilities: EngineCapabilities = [.sourceBuilds]

    private let runner: CommandRunning
    private let cache: ExecutableCache
    private var executable: URL? { cache.current }

    public var executableURL: URL? { executable }

    public init(runner: CommandRunning, executable: URL?) {
        self.runner = runner
        self.cache = ExecutableCache(locate: { executable })
    }

    public init(runner: CommandRunning, locate: @escaping @Sendable () -> URL?) {
        self.runner = runner
        self.cache = ExecutableCache(locate: locate)
    }

    // MARK: detect

    public func detect() async -> EngineStatus {
        await detectStatus(runner: runner, executable: cache.relocate(), arguments: ["version"]) { stdout in
            // "Version: 2.12.7"
            for line in stdout.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("Version:") else { continue }
                let version = text.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
                if !version.isEmpty { return version }
            }
            return nil
        }
    }

    // MARK: search / installed / outdated

    public func search(_ query: String) async throws -> [Package] {
        // Not `-q`: with `-q`, `search --line` prints names only (no version, categories or description).
        let args = try searchArguments(["search", "--line"], query: query, engine: .macports)
        let exe = try requireExecutable()
        let result = try await runner.run(exe, args)
        guard result.exitCode == 0 else {
            throw failure("port search failed", result)
        }
        // Real port prints "No match for X found" on stdout and exits 0.
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count == 1, lines[0].hasPrefix("No match for "), lines[0].hasSuffix(" found") { return [] }
        var packages: [Package] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            // name \t version \t categories \t description
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let version = fields[1].trimmingCharacters(in: .whitespaces)
            let summary = fields.count >= 4 ? fields[3...].joined(separator: "\t").trimmingCharacters(in: .whitespaces) : ""
            packages.append(Package(id: ref(name),
                                    displayName: name,
                                    latestVersion: version.isEmpty ? nil : version,
                                    summary: summary.isEmpty ? nil : summary))
        }
        try requireParsed(packages, lines, "search")
        return packages
    }

    public func listInstalled() async throws -> [Package] {
        // `-v` adds the fields after "(active)", archs among them.
        let out = try await runOK(["-v", "-q", "installed", "active"])
        var packages: [Package] = []
        for line in out.split(whereSeparator: \.isNewline) {
            // "  name @1.2.3_0+variant (active) requested_variants='+variant' platform='darwin 27' archs='arm64 x86_64' …"
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2, tokens[1].hasPrefix("@") else { continue }
            var version = tokens[1].dropFirst()
            if let plus = version.firstIndex(of: "+") { version = version[..<plus] }
            guard !version.isEmpty else { continue }
            let name = String(tokens[0])
            packages.append(Package(id: ref(name), displayName: name, installedVersion: String(version),
                                    installedArchs: Self.archs(in: line),
                                    requestedVariants: Self.requestedVariants(in: line)))
        }
        try requireParsed(packages, out.split(whereSeparator: \.isNewline).map(String.init), "installed")
        // Which ports the user asked for. `-v installed` doesn't say, so it's a second query; when that one fails,
        // the list still loads and `installedOnRequest` stays nil (unknown), which keeps every port in an export.
        if let requested = await requestedPorts() {
            for i in packages.indices { packages[i].installedOnRequest = requested.contains(packages[i].id.name) }
        }
        return packages
    }

    /// The names `port -q installed requested` lists, or nil when it fails. MacPorts 2.12.7 prints nothing and exits
    /// 0 when no port is requested, so empty output is an empty set.
    func requestedPorts() async -> Set<String>? {
        guard let out = try? await runOK(["-q", "installed", "requested"]) else { return nil }
        var names = Set<String>()
        for line in out.split(whereSeparator: \.isNewline) {
            // "  figlet @2.2.5_0 (active)"
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 2, tokens[1].hasPrefix("@") else { continue }
            names.insert(String(tokens[0]))
        }
        return names
    }

    public func listOutdated() async throws -> [Package] {
        let out = try await runOK(["-q", "outdated"])
        var packages: [Package] = []
        for line in out.split(whereSeparator: \.isNewline) {
            // "name   1.0_0 < 1.1_0", optionally followed by a reason such as "(platform darwin 24 != darwin 25)".
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard tokens.count >= 4, ["<", ">", "!="].contains(tokens[2]) else { continue }
            let name = String(tokens[0])
            packages.append(Package(id: ref(name), displayName: name,
                                    installedVersion: String(tokens[1]),
                                    latestVersion: String(tokens[3])))
        }
        try requireParsed(packages, out.split(whereSeparator: \.isNewline).map(String.init), "outdated")
        return packages
    }

    /// The archs field of one `port -v installed` line: `archs='arm64 x86_64'`. nil without the field, for
    /// `noarch`, or when no word in it is an arch BrewxPort knows.
    static func archs(in line: Substring) -> Set<Arch>? {
        guard let start = line.range(of: " archs='") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let archs = Set(rest[..<end].split(separator: " ").compactMap { Arch(rawValue: String($0)) })
        return archs.isEmpty ? nil : archs
    }

    /// The requested_variants field of one `port -v installed` line, split into signed variants:
    /// `requested_variants='+universal-x11'` gives `["+universal", "-x11"]`. Empty without the field or when it's ''.
    static func requestedVariants(in line: Substring) -> [String] {
        guard let start = line.range(of: " requested_variants='") else { return [] }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return [] }
        var variants: [String] = []
        for ch in rest[..<end] where !ch.isWhitespace {
            if ch == "+" || ch == "-" || variants.isEmpty {
                variants.append(String(ch))
            } else {
                variants[variants.count - 1].append(ch)
            }
        }
        return variants
    }

    // MARK: info

    /// `port info --name --description --homepage --version --variants --depends_lib --depends_run <name>` prints one
    /// "key: value" line per field; variants and dependencies are comma-separated. `port` matches the name ignoring
    /// case, and `name:` is the port's own spelling (`ImageMagick` for `imagemagick`).
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .macports else {
            throw EngineError(engine: .macports, message: "Package belongs to a different engine")
        }
        let name = try packageNameArguments([ref], engine: .macports)[0]
        // `info` takes patterns: only a literal port name gives one block.
        guard RootArguments.isValidPortName(name) else {
            throw EngineError(engine: .macports, message: "Invalid port name: \(name)")
        }
        let out = try await runOK(["info", "--name", "--description", "--homepage", "--version", "--variants",
                                   "--depends_lib", "--depends_run", name])
        var fields: [String: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        guard let version = nonBlank(fields["version"]) else {
            throw EngineError(engine: .macports, message: "Couldn't read port info output for \(name)")
        }
        func list(_ value: String?) -> [String] {
            var seen = Set<String>()
            return (value ?? "").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        let variants = list(fields["variants"]).compactMap { v -> String? in
            let bare = v.drop(while: { $0 == "+" || $0 == "-" })
            return bare.isEmpty ? nil : String(bare)
        }
        let dependencies = list((fields["depends_lib"] ?? "") + "," + (fields["depends_run"] ?? ""))
        return PackageDetails(ref: ref, summary: nonBlank(fields["description"]), homepage: webURL(fields["homepage"]),
                              latestVersion: version, dependencies: dependencies, variants: variants,
                              reportedName: nonBlank(fields["name"]))
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        .always
    }

    /// Installed ports that directly depend on `name`: `port -q dependents <name>`, one name per line, nothing when
    /// there are none. A port that isn't installed exits 1, which throws.
    public func installedDependents(of name: String) async throws -> Set<String> {
        let name = try packageNameArguments([ref(name)], engine: .macports)[0]
        let out = try await runOK(["-q", "dependents", name])
        return Set(out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard refs.allSatisfy({ $0.engine == .macports }) else {
            throw EngineError(engine: .macports, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .macports, message: "MacPorts can't install a specific version")
        }
        let names = try packageNameArguments(refs, engine: .macports)
        let exe = try requireExecutable()
        let verb: String
        var variants: [String] = []
        switch op {
        case .install:
            verb = "install"
            // port applies trailing variants to every port on the line, so they only make sense for one.
            guard options.variants.isEmpty || refs.count == 1 else {
                throw EngineError(engine: .macports, message: "Variants can only be given for one port at a time")
            }
            variants = options.variants
        case .markRequested, .markDependency:
            // `port setrequested` / `unsetrequested` change a flag: no variants, no flags, one or more names.
            guard options.variants.isEmpty, options.extraArgs.isEmpty else {
                throw EngineError(engine: .macports, message: "Marking a port takes no variants or options")
            }
            verb = op == .markRequested ? "setrequested" : "unsetrequested"
        case .upgrade, .remove:
            guard options.variants.isEmpty else {
                throw EngineError(engine: .macports, message: "Variants only apply to install")
            }
            verb = op == .upgrade ? "upgrade" : "uninstall"
        }
        try RootArguments.validateMacPorts(names: names, variants: variants, extraArgs: options.extraArgs)
        // Extra flags are port global options; port parses them the same after the action (port.tcl parse_options).
        return CommandSpec(executable: exe,
                           arguments: ["-N", verb] + options.extraArgs + names + variants,
                           needsRoot: true)
    }

    // MARK: helpers

    /// Non-blank output that yields no records means the format changed; fail instead of showing an empty list.
    private func requireParsed(_ packages: [Package], _ lines: [String], _ what: String) throws {
        if packages.isEmpty, lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw EngineError(engine: .macports, message: "Couldn't read port \(what) output")
        }
    }

    private func ref(_ name: String) -> PackageRef {
        PackageRef(engine: .macports, kind: .port, name: name)
    }

    private func runOK(_ args: [String]) async throws -> String {
        let exe = try requireExecutable()
        let result = try await runner.run(exe, args)
        guard result.exitCode == 0 else {
            throw failure("port \(args.joined(separator: " ")) failed", result)
        }
        return result.stdout
    }

    private func requireExecutable() throws -> URL {
        guard let executable else {
            throw EngineError(engine: .macports, message: "MacPorts isn't installed")
        }
        return executable
    }

    private func failure(_ what: String, _ result: CommandResult) -> EngineError {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(err.prefix(300))
        let suffix = excerpt.isEmpty ? "" : ": \(excerpt)"
        return EngineError(engine: .macports, message: "\(what) (exit \(result.exitCode))\(suffix)")
    }
}
