import Foundation

/// uv's tools: Python command-line tools, each in its own environment, driven through `uv tool`. Always as the user,
/// never as root (Plan 9). Found from the login shell's PATH first, then the fixed folders (`fixedFolders`).
///
/// - uv has no JSON output for `tool list`, so its text is read (`tools`), pinned to the captured output in
///   `Fixtures/uv`: a line `name vVERSION [required: …] [extras: …] [with: …] [CPython 3.x] [latest: …] (path)` per
///   tool, each bracket only when asked for, then a `- executable` line for each of its executables.
/// - A tool is keyed by its name, which is its package's PEP 503 name; `uv tool upgrade` and `uninstall` take it.
/// - Outdated tools come from uv itself (`tool list --outdated`, uv 0.10.10 and later), which knows the index and
///   uv's settings. uv reports the newest version whatever requirement a tool was installed with, so a version
///   counts only when `uv tool upgrade` would move to it (`updates`); a tool whose range leaves uv's version out is
///   looked up on PyPI for the newest one inside it (R41, `inRangeUpdates`). An older uv is checked against PyPI's
///   JSON instead (`pypiUpdates`, through `PyPI`).
/// - PyPI has no search, so Discover looks up the exact project name there (`search`), and details come from PyPI.
/// - A tool installed from a URL, a path or git shows that source as its requirement, which can hold a token. It's
///   never kept, logged or shown: the list keeps only that the tool isn't from an index.
public struct UvEngine: Engine, InstallLocationReporting, EngineNoteReporting {
    public let id: EngineID = .uv
    /// No JSON output: `tool list` prints text.
    public let capabilities: EngineCapabilities = []

    /// The first uv that reports outdated tools itself (`tool list --outdated`, astral-sh/uv#18318).
    static let outdatedCheckVersion = "0.10.10"
    /// The first uv that names each tool's Python (`tool list --show-python`, astral-sh/uv#15814), which the PyPI
    /// check matches releases' Python requirements against.
    static let showPythonVersion = "0.9.2"

    /// Every uv call but `--version` ends its options with these: no colours (NO_COLOR is set too) and no progress
    /// bars.
    static let quiet = ["--color", "never", "--no-progress"]
    static let toolDirArguments = ["tool", "dir"] + quiet
    static let binDirArguments = ["tool", "dir", "--bin"] + quiet
    /// Every tool with the requirement it was installed with (uv 0.4.6 and later).
    static let listArguments = ["tool", "list", "--show-version-specifiers"] + quiet
    static let outdatedArguments = ["tool", "list", "--show-version-specifiers", "--outdated"] + quiet
    /// The list an older uv's PyPI check reads, with each tool's Python, in the flags it was captured with (the
    /// extras, `--with` packages and paths are skipped). Every flag predates `--show-python` (0.9.2): `--show-paths`
    /// came in 0.2.27 (astral-sh/uv#5164), `--show-version-specifiers` in 0.4.6 (#7050), `--show-with` in 0.7.3
    /// (#13264) and `--show-extras` in 0.7.10 (#13783).
    static let pythonListArguments = ["tool", "list", "--show-version-specifiers", "--show-with", "--show-extras",
                                      "--show-python", "--show-paths"] + quiet

    private let tool: LanguageTool
    private let registry: any RegistryFetching
    private let state = State()
    private let access: InstallAccessState
    private let home: String
    /// Reads a tool's own files (its receipt, `uv-receipt.toml`, and its `pyvenv.cfg`).
    private let readToolFile: ToolFileReader
    /// Whether a tool's `bin/python` link is still there (R41).
    private let toolPathExists: ToolPathCheck

    public var executableURL: URL? { tool.executable }

    /// Why this account can't change uv's tools: the last detect found the tools' folder or their bin folder not
    /// writable.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// The tools' folder (`uv tool dir`) as the last `detect()` read it: where each tool's environment lives.
    public var installLocation: URL? { state.toolDirectory }

    /// The tools' executables' folder (`uv tool dir --bin`) as the last `detect()` read it, which pipx may share.
    public var binLocation: URL? { state.binDirectory }

    /// What uv said on stderr while it last listed its tools (`listNote`): a broken tool it left out. Nil when it said
    /// nothing.
    public var note: String? { state.note }

    /// The app's uv: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `registry`
    /// reads PyPI; `base` is the environment every command starts from; `isWritable` is the access check.
    public init(runner: CommandRunning, registry: any RegistryFetching, loginShell: @escaping LoginShellContextProvider,
                arch: Arch = .current, base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable,
                readToolFile: @escaping ToolFileReader = ToolFiles.read,
                toolPathExists: @escaping ToolPathCheck = ToolFiles.entryExists) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .uv, name: "uv", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        self.home = home
        self.readToolFile = readToolFile
        self.toolPathExists = toolPathExists
    }

    /// uv at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed. Its
    /// folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, registry: any RegistryFetching, executable: URL?,
                captured: [String: String] = [:], base: [String: String] = ProcessRunner.baseEnvironment,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true },
                readToolFile: @escaping ToolFileReader = ToolFiles.read,
                toolPathExists: @escaping ToolPathCheck = ToolFiles.entryExists) {
        tool = LanguageTool(engine: .uv, name: "uv", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        home = LanguageTool.home(base)
        self.readToolFile = readToolFile
        self.toolPathExists = toolPathExists
    }

    // MARK: finding uv

    /// Where uv is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first),
    /// MacPorts', nanobrew's, then the standalone installer's (XDG_BIN_HOME, then `~/.local/bin`) and the folders
    /// older installers and `cargo install` used (CARGO_HOME's bin, then `~/.cargo/bin`).
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: as one chained expression it was too slow for the CI compiler to type-check.
        let homebrew: [String] = arch == .arm64 ? ["/opt/homebrew/bin", "/usr/local/bin"]
                                                : ["/usr/local/bin", "/opt/homebrew/bin"]
        let others: [String] = ["/opt/local/bin", "/opt/nanobrew/prefix/bin"]
        var installer: [String] = []
        if let xdg = captured["XDG_BIN_HOME"] { installer.append(xdg) }
        installer.append(home + "/.local/bin")
        var cargo: [String] = []
        if let cargoHome = captured["CARGO_HOME"] { cargo.append(cargoHome + "/bin") }
        cargo.append(home + "/.cargo/bin")
        return homebrew + others + installer + cargo
    }

    // MARK: detect

    /// uv's version (which decides how outdated tools are checked), then its tools' folder and their executables'
    /// folder. A folder uv doesn't give leaves uv present, without it.
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { Self.version($0) }
        var version: String?
        var tools: URL?
        var bin: URL?
        if case .present(_, let found) = status {
            version = found
            tools = await folder(Self.toolDirArguments)
            bin = await folder(Self.binDirArguments)
        }
        state.detected(version: version, toolDirectory: tools, binDirectory: bin)
        access.checked(.uv, folders: [tools, bin].compactMap { $0 }, home: home)
        return status
    }

    /// The version in `uv --version`'s first line: `uv 0.13.10 (Homebrew 2026-11-24 aarch64-apple-darwin)`.
    static func version(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == "uv", EcosystemVersion.isValid(String(words[1]), scheme: .pep440)
        else { return nil }
        return String(words[1])
    }

    private func folder(_ arguments: [String]) async -> URL? {
        guard let result = try? await tool.run(arguments), result.exitCode == 0,
              let line = result.stdout.split(whereSeparator: \.isNewline).first else { return nil }
        let path = line.trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    // MARK: the tool list

    /// One tool as `uv tool list` prints it.
    struct Tool: Equatable, Sendable {
        let name: String
        let version: String
        /// The version requirement it was installed with (`[required: ==0.6.0]`); nil when it has none, or isn't
        /// from an index.
        let requirement: PyPI.Specifier?
        /// Installed by name from an index: no requirement, or one of versions. A requirement BrewxPort can't read
        /// as versions is a URL, a path or git, which uv doesn't upgrade from an index.
        let fromIndex: Bool
        /// The tool's Python (`[CPython 3.15.2]`, with `--show-python`), as its release number.
        let python: String?
        /// The newest version uv found (`[latest: 9.0.2]`, with `--outdated`).
        let latest: String?

        /// Installed with an exact version (`uv tool install ruff==0.6.0`), which `uv tool upgrade` never moves.
        var isPinned: Bool { requirement?.isExact == true }
    }

    /// The tools in `uv tool list`'s output, sorted by name. A line that is neither a tool nor one of its executables
    /// (`- name`) means the output isn't one BrewxPort knows, which is a failure rather than a short list.
    static func tools(_ output: String) throws -> [Tool] {
        var tools: [Tool] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard !line.allSatisfy(\.isWhitespace), !line.hasPrefix("- ") else { continue }
            guard let tool = parsed(line) else {
                throw EngineError(engine: .uv, message: "Couldn't read uv's tool list: it has a line BrewxPort "
                                  + "doesn't know.")
            }
            tools.append(tool)
        }
        return tools.sorted { $0.name < $1.name }
    }

    /// One tool line: its name, ` v`, its version, then ` [...]` groups (brackets inside one are counted) and maybe
    /// ` (path)`. Nil for anything else.
    private static func parsed(_ line: Substring) -> Tool? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[..<space])
        var rest = line[line.index(after: space)...]
        guard PackageNameRules.isValid(name, for: .uv), rest.first == "v" else { return nil }
        rest = rest.dropFirst()
        let versionEnd = rest.firstIndex(of: " ") ?? rest.endIndex
        let version = String(rest[..<versionEnd])
        guard !version.isEmpty else { return nil }
        rest = rest[versionEnd...]

        var required: Substring?
        var python: String?
        var latest: String?
        while rest.hasPrefix(" [") {
            let open = rest.index(after: rest.startIndex)
            var depth = 0
            var close: Substring.Index?
            var index = open
            while index < rest.endIndex {
                if rest[index] == "[" { depth += 1 }
                if rest[index] == "]" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
                index = rest.index(after: index)
            }
            guard let close else { return nil }
            let group = rest[rest.index(after: open)..<close]
            if let value = value(group, "required: ") {
                required = value
            } else if let value = value(group, "latest: ") {
                latest = nonBlank(String(value))
            } else if !group.contains(":") {
                // The Python: `CPython 3.15.2`, `PyPy 3.10.14`.
                let words = group.split(separator: " ")
                if words.count == 2 { python = PyPI.pythonVersion(String(words[1])) }
            }
            // `with: …` and `extras: …` aren't used.
            rest = rest[rest.index(after: close)...]
        }
        guard rest.isEmpty || rest.hasPrefix(" (") else { return nil }

        // Read and dropped: a requirement that isn't versions is the install source, which can hold a token.
        let specifier = required.flatMap { PyPI.Specifier(String($0)) }
        return Tool(name: name, version: version, requirement: specifier,
                    fromIndex: required == nil || specifier != nil, python: python, latest: latest)
    }

    private static func value(_ group: Substring, _ label: String) -> Substring? {
        group.hasPrefix(label) ? group.dropFirst(label.count) : nil
    }

    // MARK: installed

    /// `uv tool list`: every tool, each asked for. uv leaves a broken tool out, with a warning on stderr, which is
    /// kept as the engine's `note` so the tool doesn't vanish without a word.
    public func listInstalled() async throws -> [Package] {
        try await listTools(Self.listArguments).map { tool in
            Package(id: ref(tool.name), displayName: tool.name, installedVersion: tool.version,
                    installedOnRequest: true)
        }
    }

    private func listTools(_ arguments: [String]) async throws -> [Tool] {
        let result = try await tool.run(arguments)
        guard result.exitCode == 0 else { throw tool.failure("uv tool list failed", result) }
        let tools = try Self.tools(result.stdout)
        state.listed(note: Self.listNote(result.stderr))
        return tools
    }

    /// What uv printed on stderr while listing (a broken tool's warning; the shape wasn't captured), as one line for
    /// the engine page: without URL credentials, cut at 300 characters. Nil when there's nothing but uv's "No tools
    /// installed" (`tool-list-empty-stderr.txt`).
    static func listNote(_ stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "No tools installed" }
        guard !lines.isEmpty else { return nil }
        let text = CredentialScrubber.scrub(lines.joined(separator: " "))
        return "uv said while listing its tools: " + String(text.prefix(300))
    }

    // MARK: outdated

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// uv 0.10.10 and later check for themselves; an older uv (as `detect()` found it) is checked against PyPI, where
    /// a tool that couldn't be looked up is named in `unchecked` (R6). uv's own check has no partial answer: one
    /// lookup that fails stops all of it.
    public func checkOutdated() async throws -> OutdatedReport {
        if let version = state.version,
           EcosystemVersion.compare(version, Self.outdatedCheckVersion, scheme: .pep440) == .orderedAscending {
            return try await outdatedFromPyPI(namesPython: EcosystemVersion.compare(
                version, Self.showPythonVersion, scheme: .pep440) != .orderedAscending)
        }
        let result = try await tool.run(Self.outdatedArguments)
        // One lookup that fails stops uv's whole check (exit 2, nothing on stdout): its words are on stderr.
        guard result.exitCode == 0 else { throw tool.failure("uv tool list --outdated failed", result) }
        state.listed(note: Self.listNote(result.stderr))
        let tools = try Self.tools(result.stdout)
        let offered = Self.updates(tools)
        let ranged = withVenvPython(Self.outOfRange(tools))
        guard !ranged.isEmpty else { return OutdatedReport(packages: offered) }
        let names = Set(ranged.map { PackageNameRules.normalizedPythonName($0.name) }).sorted()
        let found = Self.inRangeUpdates(ranged, projects: try await PyPI.projects(names, for: .uv, from: registry))
        return OutdatedReport(packages: (offered + found.packages).sorted { $0.id.name < $1.id.name },
                              unchecked: found.unchecked)
    }

    /// R41: the tools uv's own check gave a newest version that their range requirement leaves out (`isort>=5,<7` at
    /// 5.13.2, `[latest: 9.0.2]`, `Fixtures/uv/t13-list-outdated-many.txt`). `uv tool upgrade` still moves them inside
    /// the range (to 6.1.0, `t13-upgrade-isort-in-range`), so PyPI is asked for the newest version there
    /// (`inRangeUpdates`). Only tools from an index with a requirement that isn't an exact pin.
    static func outOfRange(_ tools: [Tool]) -> [Tool] {
        tools.filter { tool in
            guard tool.fromIndex, !tool.isPinned, let requirement = tool.requirement, let latest = tool.latest else {
                return false
            }
            return !requirement.allows(latest)
        }
    }

    /// R41: each `outOfRange` tool's newest release inside its requirement on PyPI (not yanked, fitting its Python,
    /// newer by PEP 440, and no pre-release for a stable install), which `uv tool upgrade <name>` moves to. A lookup
    /// that fails names that tool in `unchecked` (R6); uv's own check answered, so it never fails the check.
    static func inRangeUpdates(_ tools: [Tool], projects: [String: Result<PyPI.Project, any Error>]) -> OutdatedReport {
        var rows: [Package] = []
        let unchecked = (try? OutdatedLookups.tally(
            tools, answers: projects, key: { PackageNameRules.normalizedPythonName($0.name) }, name: \.name,
            noAnswer: { _ in nil }
        ) { tool, project in
            guard let newer = project.newerVersion(than: tool.version, python: tool.python, meeting: tool.requirement)
            else { return }
            rows.append(Package(id: PackageRef(engine: .uv, kind: .tool, name: tool.name), displayName: tool.name,
                                installedVersion: tool.version, latestVersion: newer))
        }) ?? .none
        return OutdatedReport(packages: rows.sorted { $0.id.name < $1.id.name }, unchecked: unchecked)
    }

    /// `tools`, each without a Python from the listing given the one its `pyvenv.cfg` (in `uv tool dir`) names, when
    /// that can be read (`--outdated` doesn't say).
    func withVenvPython(_ tools: [Tool]) -> [Tool] {
        tools.map { tool in
            guard tool.python == nil, let python = venvConfig(tool.name).flatMap(VenvConfig.version) else { return tool }
            return Tool(name: tool.name, version: tool.version, requirement: tool.requirement,
                        fromIndex: tool.fromIndex, python: python, latest: tool.latest)
        }
    }

    /// The text of `name`'s `pyvenv.cfg` in `uv tool dir`; nil when the folder isn't known yet, the name isn't one
    /// plain folder name, or the file can't be read.
    func venvConfig(_ name: String) -> String? {
        guard let path = toolPath(name, "pyvenv.cfg"), let data = try? readToolFile(path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `<uv tool dir>/<name>/<file>`; nil when the folder isn't known yet or `name` isn't one plain folder name.
    private func toolPath(_ name: String, _ file: String) -> String? {
        guard VenvConfig.isPlainFolderName(name), let folder = state.toolDirectory else { return nil }
        return folder.appendingPathComponent(name, isDirectory: true).appendingPathComponent(file).path
    }

    /// The tools uv reported a newer version for that `uv tool upgrade` would move to: from an index, the version
    /// meets the requirement the tool was installed with (so never an exact pin: uv reports the newest version
    /// whatever the requirement), and by PEP 440 it's newer, and not a pre-release for a stable install.
    static func updates(_ tools: [Tool]) -> [Package] {
        tools.compactMap { tool in
            guard tool.fromIndex, let latest = tool.latest, tool.requirement?.allows(latest) != false,
                  let newer = EcosystemVersion.newerVersion(than: tool.version, among: [latest], scheme: .pep440)
            else { return nil }
            return Package(id: PackageRef(engine: .uv, kind: .tool, name: tool.name), displayName: tool.name,
                           installedVersion: tool.version, latestVersion: newer)
        }.sorted { $0.id.name < $1.id.name }
    }

    // MARK: outdated (PyPI, for a uv before 0.10.10)

    /// Each tool's project looked up on PyPI, a few at a time. A lookup that fails (no such project, too large,
    /// offline) leaves that tool out; when every one fails, the check fails. `namesPython`: uv can name each tool's
    /// Python (0.9.2 and later); before that, releases' Python requirements aren't checked.
    private func outdatedFromPyPI(namesPython: Bool) async throws -> OutdatedReport {
        let tools = try await listTools(namesPython ? Self.pythonListArguments : Self.listArguments)
        let names = Self.pypiNames(tools)
        guard !names.isEmpty else { return OutdatedReport(packages: []) }
        return try Self.pypiUpdates(tools, projects: try await PyPI.projects(names, for: .uv, from: registry))
    }

    /// A tool the PyPI check covers: installed by name from an index, and not pinned.
    private static func checksOnPyPI(_ tool: Tool) -> Bool { tool.fromIndex && !tool.isPinned }

    /// The PEP 503 names to look up for `tools`, each once, sorted.
    static func pypiNames(_ tools: [Tool]) -> [String] {
        Set(tools.filter(checksOnPyPI).map { PackageNameRules.normalizedPythonName($0.name) }).sorted()
    }

    /// The updates PyPI's answers give `tools` (keyed by PEP 503 name): each one's newest release that isn't yanked,
    /// fits its Python and meets its requirement. A tool whose lookup failed is in `unchecked`. Throws when there was
    /// something to check and no answer came back.
    static func pypiUpdates(_ tools: [Tool], projects: [String: Result<PyPI.Project, any Error>]) throws
        -> OutdatedReport {
        var rows: [Package] = []
        let unchecked = try OutdatedLookups.tally(
            tools.filter(checksOnPyPI), answers: projects, key: { PackageNameRules.normalizedPythonName($0.name) },
            name: \.name, noAnswer: { $0.map { PyPI.noAnswer($0, for: .uv) } }
        ) { tool, project in
            guard let newer = project.newerVersion(than: tool.version, python: tool.python, meeting: tool.requirement)
            else { return }
            rows.append(Package(id: PackageRef(engine: .uv, kind: .tool, name: tool.name), displayName: tool.name,
                                installedVersion: tool.version, latestVersion: newer))
        }
        return OutdatedReport(packages: rows.sorted { $0.id.name < $1.id.name }, unchecked: unchecked)
    }

    // MARK: search and info

    /// PyPI has no search, so the query is looked up as an exact project name (`PyPI.search`).
    public func search(_ query: String) async throws -> [Package] {
        try await PyPI.search(query, for: .uv, from: registry)
    }

    /// The tool's project on PyPI: its summary, home page and newest release.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .uv, ref.kind == .tool else {
            throw EngineError(engine: .uv, message: "Package belongs to a different engine")
        }
        return try await PyPI.details(ref, project: ref.name, from: registry)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// `uv tool install` takes one package, and so does its repair (`install --reinstall`).
    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? {
        operation == .install || operation == .repair ? 1 : nil
    }

    /// `uv tool install` with one PyPI name (`maxTargetsPerCommand`), `upgrade` and `uninstall` with tool names.
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard !refs.isEmpty else { throw EngineError(engine: .uv, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .uv && $0.kind == .tool }) else {
            throw EngineError(engine: .uv, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .uv, message: "uv installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .uv, message: "uv has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .uv, message: "uv commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .uv)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .uv) }
        try requireTargetLimit(refs, for: op)
        let names = refs.map(\.name)
        switch op {
        case .install: return try tool.command(["tool", "install"] + Self.quiet + names)
        case .upgrade: return try tool.command(["tool", "upgrade"] + Self.quiet + names)
        case .remove: return try tool.command(["tool", "uninstall"] + Self.quiet + names)
        case .repair:
            throw EngineError(engine: .uv, message: "uv repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .uv, message: "uv can't mark packages")
        }
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .uv, kind: .tool, name: name) }

    /// What the last `detect()` and listing found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedVersion: String?
        private var tools: URL?
        private var bin: URL?
        private var listNote: String?

        var version: String? { lock.withLock { detectedVersion } }
        var toolDirectory: URL? { lock.withLock { tools } }
        var binDirectory: URL? { lock.withLock { bin } }
        var note: String? { lock.withLock { listNote } }

        func listed(note: String?) { lock.withLock { listNote = note } }

        func detected(version: String?, toolDirectory: URL?, binDirectory: URL?) {
            lock.withLock {
                detectedVersion = version
                tools = toolDirectory
                bin = binDirectory
            }
        }
    }
}

// MARK: Task 10: runtime and repair

extension UvEngine: RuntimeReporting, ToolRepairing {
    /// The Homebrew Pythons uv's tools run on, each with its tools, from a fresh `tool list --show-python` (uv 0.9.2
    /// and later). uv names a tool's Python by version only, so CPython 3.15 counts as Homebrew's python@3.15: the
    /// careful reading, since uv can use Homebrew's Python. Each tool's `pyvenv.cfg` (in `uv tool dir`) says whether
    /// it survives a patch update (R29). Throws when uv can't name them (an older uv, a failed listing).
    public func runtimeUses() async throws -> [RuntimeUse] {
        guard let version = state.version,
              EcosystemVersion.compare(version, Self.showPythonVersion, scheme: .pep440) != .orderedAscending else {
            throw EngineError(engine: .uv, message: "This uv doesn't say which Python its tools use")
        }
        let tools = try await listTools(Self.pythonListArguments)
        return PipxEngine.uses(tools.map { tool in
            // A name that isn't one plain folder name isn't used in a path: its tool counts as unknown.
            let home = venvConfig(tool.name).flatMap(VenvConfig.home)
            return (tool.name, tool.python.flatMap(HomebrewFormula.python(version:)).map { [$0] } ?? [], home)
        })
    }

    /// R28: `uv tool install --reinstall` for each tool, one per command, sorted, with everything uv's receipt recorded
    /// for it: the Python it was asked for (`--python`), its `--with` packages, and its own extras and version
    /// requirement (`ruff==0.6.0`, the captured shape). Read from the receipt, which stays when uv's list leaves a tool
    /// out because its Python is gone. A tool the receipt can't give back exactly is left out (`repairRefusals`).
    /// R41: without a Python in the receipt, the venv's own `major.minor` (its `pyvenv.cfg`), so uv never moves the
    /// tool to a Python of its choosing; `--force` when the venv's `bin/python` link itself is gone.
    public func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        try access.requireWritable(for: .repair, engine: .uv)
        let names = Set(tools).sorted()
        var commands: [RepairCommand] = []
        var refused = false
        for name in names {
            switch repair(name) {
            case .success(let arguments): commands.append(RepairCommand(tool: name, spec: try tool.command(arguments)))
            case .failure: refused = true
            }
        }
        guard !commands.isEmpty || refused else {
            throw EngineError(engine: .uv, message: "uv has no tools BrewxPort can repair")
        }
        return commands
    }

    /// The tools `repairCommands` leaves out, each with its reason.
    public func repairRefusals(for tools: [String]) -> [String: String] {
        var refusals: [String: String] = [:]
        for name in Set(tools).sorted() {
            if case .failure(let reason) = repair(name) { refusals[name] = reason.message }
        }
        return refusals
    }

    /// The arguments that install `name` again as its receipt (`<uv tool dir>/<name>/uv-receipt.toml`) says, or why
    /// not, in one line.
    func repair(_ name: String) -> Result<[String], EngineError> {
        func refused(_ text: String) -> Result<[String], EngineError> {
            .failure(EngineError(engine: .uv, message: text))
        }
        guard PackageNameRules.isValid(name, for: .uv) else {
            return refused("BrewxPort doesn't repair \(name): it isn't a name uv installs by.")
        }
        guard let folder = state.toolDirectory else {
            return refused("BrewxPort doesn't know where uv keeps its tools yet, so it doesn't repair \(name).")
        }
        let path = folder.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("uv-receipt.toml").path
        let data: Data?
        do {
            data = try readToolFile(path)
        } catch {
            return refused(Self.unreadableReceipt(name))
        }
        guard let data else { return refused("uv has no record of \(name), so BrewxPort doesn't repair it.") }
        guard let receipt = UvReceipt(String(decoding: data, as: UTF8.self)) else {
            return refused(Self.unreadableReceipt(name))
        }
        let venvPython = receipt.python == nil ? venvConfig(name).flatMap(VenvConfig.minorVersion) : nil
        let linkGone = !toolPathExists(folder.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("bin/python").path)
        return Self.repairArguments(name, receipt: receipt, venvPython: venvPython, pythonLinkGone: linkGone)
            .mapError { EngineError(engine: .uv, message: $0.text) }
    }

    static func unreadableReceipt(_ name: String) -> String {
        "BrewxPort couldn't read uv's record of \(name), so it doesn't repair it."
    }

    /// Why a receipt can't be given back exactly, in one line.
    struct RepairRefusal: Error, Equatable {
        let text: String
    }

    /// `tool install --reinstall`'s arguments for `name` from its receipt (R28). Every value is checked as R11 checks
    /// Cargo's: names by PEP 503 rules, extras as names, version requirements only when BrewxPort reads them as
    /// versions (written back in its own form), and the Python request only as a plain version or implementation
    /// (never a path). Refused, each with its reason: a requirement from a URL, a path or a repository; one with a
    /// marker or an index; constraints, overrides, index or resolver settings; and commands from other packages.
    /// R41: `venvPython` (the venv's `major.minor`) is the Python asked for when the receipt names none, and
    /// `pythonLinkGone` adds `--force`, without which uv refuses a venv missing its Python
    /// (`Fixtures/uv/t13-repair-tabulate`, exit 2; `t13-repair-tabulate-force` works).
    static func repairArguments(_ name: String, receipt: UvReceipt, venvPython: String? = nil,
                                pythonLinkGone: Bool = false) -> Result<[String], RepairRefusal> {
        func refused(_ text: String) -> Result<[String], RepairRefusal> { .failure(RepairRefusal(text: text)) }
        let key = PackageNameRules.normalizedPythonName(name)
        let sources: Set<String> = ["git", "url", "path", "directory", "editable", "subdirectory"]
        if receipt.requirements.contains(where: { !$0.otherKeys.isDisjoint(with: sources) }) {
            return refused("\(name) was installed from a URL, a path or git, so BrewxPort doesn't repair it by name.")
        }
        if receipt.requirements.contains(where: { !$0.otherKeys.isEmpty }) || receipt.hasConstraints
            || receipt.hasOptions {
            return refused("\(name) was installed with uv settings BrewxPort doesn't pass back (a marker, an index, "
                           + "constraints or overrides), so it doesn't repair it.")
        }
        guard receipt.commandsFrom.allSatisfy({ PackageNameRules.normalizedPythonName($0) == key }) else {
            return refused("\(name) was installed with commands from other packages, so BrewxPort doesn't repair it.")
        }
        let own = receipt.requirements.filter { PackageNameRules.normalizedPythonName($0.name) == key }
        guard own.count == 1, let main = own.first else { return refused(unreadableReceipt(name)) }
        var arguments = ["tool", "install", "--reinstall"] + (pythonLinkGone ? ["--force"] : []) + quiet
        if let python = receipt.python {
            guard isPythonRequest(python) else {
                return refused("\(name) was installed for a Python given by its path, so BrewxPort doesn't repair it.")
            }
            arguments += ["--python", python]
        } else if let venvPython, isPythonRequest(venvPython) {
            arguments += ["--python", venvPython]
        }
        for requirement in receipt.requirements where requirement != main {
            guard let spec = requirementText(requirement) else { return refused(unreadableReceipt(name)) }
            arguments += ["--with", spec]
        }
        guard let spec = requirementText(main) else { return refused(unreadableReceipt(name)) }
        return .success(arguments + [spec])
    }

    /// `black[d]>=24,<24.3.0`: a checked name, checked extras and a version requirement BrewxPort reads, written in its
    /// own form; nil for anything else.
    static func requirementText(_ requirement: UvReceipt.Requirement) -> String? {
        guard PackageNameRules.isValid(requirement.name, for: .uv),
              requirement.extras.allSatisfy({ PackageNameRules.isValid($0, for: .uv) }) else { return nil }
        var text = requirement.name
        if !requirement.extras.isEmpty { text += "[" + requirement.extras.joined(separator: ",") + "]" }
        if let written = requirement.specifier {
            guard let specifier = PyPI.Specifier(written), !specifier.clauses.isEmpty else { return nil }
            text += specifier.clauses.map { $0.op + $0.version }.joined(separator: ",")
        }
        return text
    }

    /// A Python request uv takes that names no file: a version (`3.12`, `>=3.11`) or an implementation with one
    /// (`cpython@3.12`, `pypy3.10`). Never a path, and never something that reads as an option.
    static func isPythonRequest(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.@+<>=!~,_-")
        return !text.isEmpty && !text.hasPrefix("-") && text.unicodeScalars.allSatisfy(allowed.contains)
    }
}

