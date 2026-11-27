import Foundation

/// pipx's tools: Python command-line tools, each in its own virtual environment ("venv"), driven through `pipx` and
/// its JSON output. Always as the user, never as root (Plan 9). Found from the login shell's PATH first, then the
/// fixed folders (`fixedFolders`).
///
/// - A tool is keyed by its venv's name (the package's name plus any `--suffix`), which `pipx upgrade` and `pipx
///   uninstall` take. Its PyPI project is the venv's main package.
/// - Outdated tools come from pipx itself (`list --outdated`, pipx 1.15.1 and later), which knows the index, the
///   tool's Python and pipx's own settings. An older pipx is checked against PyPI's JSON instead (`pypiUpdates`).
/// - PyPI has no search, so Discover looks up the exact project name there (`search`), and details come from PyPI.
///   The lookups, and the Python requirement rules, are shared with uv (`PyPI`).
/// - pipx backs its tools with pip or uv, whichever it picks; nothing here depends on which.
/// - `package_or_url` and `pip_args` in pipx's metadata are what the user typed, and can hold an index URL with a
///   token. They're never kept, logged or shown: the list keeps only whether the spec named a package on an index.
public struct PipxEngine: Engine, InstallLocationReporting, EngineNoteReporting {
    public let id: EngineID = .pipx
    public let capabilities: EngineCapabilities = [.jsonOutput]

    /// The first pipx that reports outdated tools itself (`list --outdated --output json`): 1.15.0 refuses the flags,
    /// 1.15.1 answers (`Fixtures/pipx/t13-old-1.15.0-*`, `t13-old-1.15.1-*`).
    static let outdatedCheckVersion = "1.15.1"

    private let tool: LanguageTool
    private let registry: any RegistryFetching
    private let state = State()
    private let access: InstallAccessState
    private let home: String
    private let readToolFile: ToolFileReader

    public var executableURL: URL? { tool.executable }

    /// PIPX_HOME (`pipx environment --value PIPX_HOME`) as the last `detect()` read it: where the tools' venvs live.
    public var installLocation: URL? { state.home }

    /// PIPX_BIN_DIR (`pipx environment --value PIPX_BIN_DIR`) as the last `detect()` read it: where the tools'
    /// commands go, which uv may share.
    public var binLocation: URL? { state.bin }

    /// Why this account can't change pipx's tools: the last detect found PIPX_HOME or PIPX_BIN_DIR not writable.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// R40: how many tools the last `pipx list` left out because their venv is broken (`brokenNote`), for pipx's page.
    /// Nil when it listed every one.
    public var note: String? { state.note }

    /// The app's pipx: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `registry`
    /// reads PyPI; `base` is the environment every command starts from; `isWritable` is the access check.
    public init(runner: CommandRunning, registry: any RegistryFetching, loginShell: @escaping LoginShellContextProvider,
                arch: Arch = .current, base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable,
                readToolFile: @escaping ToolFileReader = ToolFiles.read) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .pipx, name: "pipx", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        self.home = home
        self.readToolFile = readToolFile
    }

    /// pipx at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed. Its
    /// folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, registry: any RegistryFetching, executable: URL?,
                captured: [String: String] = [:], base: [String: String] = ProcessRunner.baseEnvironment,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true },
                readToolFile: @escaping ToolFileReader = ToolFiles.read) {
        tool = LanguageTool(engine: .pipx, name: "pipx", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        home = LanguageTool.home(base)
        self.readToolFile = readToolFile
    }

    // MARK: finding pipx

    /// Where pipx is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first),
    /// MacPorts', nanobrew's, pipx's own bin folder (where `pipx install pipx` puts it: PIPX_BIN_DIR, then
    /// `~/.local/bin`), then `pip install --user`'s folders, newest Python first.
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        var folders: [String] = arch == .arm64 ? ["/opt/homebrew/bin", "/usr/local/bin"]
                                               : ["/usr/local/bin", "/opt/homebrew/bin"]
        folders += ["/opt/local/bin", "/opt/nanobrew/prefix/bin"]
        if let pipxBin = captured["PIPX_BIN_DIR"] { folders.append(pipxBin) }
        folders.append(home + "/.local/bin")
        folders += pythonUserBins(home: home)
        return folders
    }

    /// `~/Library/Python/<version>/bin` for each Python that has one, newest first.
    static func pythonUserBins(home: String) -> [String] {
        let folder = home + "/Library/Python"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { EcosystemVersion.isValid($0, scheme: .pep440) }
            .sorted { EcosystemVersion.compare($0, $1, scheme: .pep440) == .orderedDescending }
        return versions.map { folder + "/" + $0 + "/bin" }
    }

    // MARK: detect

    /// pipx's version (which decides how outdated tools are checked), then PIPX_HOME for `installLocation` and
    /// PIPX_BIN_DIR for `binLocation`, and whether this account can write both. A folder pipx doesn't give leaves pipx
    /// present, without it.
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { stdout in
            guard let line = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let version = line.trimmingCharacters(in: .whitespaces)
            return EcosystemVersion.isValid(version, scheme: .pep440) ? version : nil
        }
        var version: String?
        var venvs: URL?
        var bin: URL?
        if case .present(_, let found) = status {
            version = found
            venvs = await folder("PIPX_HOME")
            bin = await folder("PIPX_BIN_DIR")
        }
        state.detected(version: version, home: venvs, bin: bin)
        access.checked(.pipx, folders: [venvs, bin].compactMap { $0 }, home: home)
        return status
    }

    /// `pipx environment --value <name>`'s answer, when it's an absolute path.
    private func folder(_ name: String) async -> URL? {
        guard let result = try? await tool.run(["environment", "--value", name]), result.exitCode == 0,
              let line = result.stdout.split(whereSeparator: \.isNewline).first else { return nil }
        let path = line.trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }

    // MARK: installed

    /// `pipx list --json`, as much of it as BrewxPort uses. `package_or_url` is read only to tell whether it named a
    /// package on an index, and `pip_args` isn't read at all.
    struct ListAnswer: Decodable {
        struct Environment: Decodable {
            let metadata: Metadata
        }

        struct Metadata: Decodable {
            let mainPackage: MainPackage
            let pythonVersion: String?
            /// The Python the venv was made with (`{"__type__": "Path", "__Path__": …}`); older pipx doesn't say.
            let sourceInterpreter: PathValue?

            enum CodingKeys: String, CodingKey {
                case mainPackage = "main_package"
                case pythonVersion = "python_version"
                case sourceInterpreter = "source_interpreter"
            }
        }

        /// A path as pipx's metadata writes one.
        struct PathValue: Decodable {
            let path: String

            enum CodingKeys: String, CodingKey { case path = "__Path__" }
        }

        struct MainPackage {
            let package: String
            let packageVersion: String?
            let pinned: Bool
            /// The spec it was installed from named a package on an index, not a URL, a path or a git repository.
            let fromIndex: Bool
        }

        let venvs: [String: Environment]
    }

    /// One tool pipx lists, keyed by its venv.
    struct Venv: Equatable, Sendable {
        /// The venv's name: the package's own name plus any suffix. `upgrade` and `uninstall` take it.
        let name: String
        /// The PyPI project the venv was made for (`main_package.package`).
        let project: String
        let version: String?
        /// The venv's Python, as its release number ("3.15.2").
        let python: String?
        let pinned: Bool
        let fromIndex: Bool
        /// The Python executable the venv was made with, when pipx says.
        var interpreter: String? = nil

        /// The Homebrew formulae the venv's Python may belong to (`homebrewPythons(interpreter:version:)`).
        var homebrewPythons: [String] { PipxEngine.homebrewPythons(interpreter: interpreter, version: python) }
    }

    /// The Homebrew formulae a venv's Python may belong to, both counted (the careful direction: an extra hold at
    /// worst): the one its interpreter's path names today, and the one its version names (`3.15.2` → `python@3.15`).
    /// An unversioned path (`/opt/homebrew/bin/python3`) resolves to whatever Homebrew links there now, which may not
    /// be the Python the venv was made with. `realPath` is realpath(3); tests pass their own.
    static func homebrewPythons(interpreter: String?, version: String?,
                                realPath: (String) -> String? = ToolLocator.realPath) -> [String] {
        let found = [interpreter.flatMap { HomebrewFormula.owning($0, realPath: realPath) },
                     version.flatMap(HomebrewFormula.python(version:))].compactMap { $0 }
        return Array(Set(found)).sorted()
    }

    /// The venvs in `answer`, sorted by name.
    static func venvs(_ answer: ListAnswer) -> [Venv] {
        answer.venvs.sorted { $0.key < $1.key }.map { name, environment in
            let main = environment.metadata.mainPackage
            return Venv(name: name, project: main.package, version: nonBlank(main.packageVersion),
                        python: PyPI.pythonVersion(environment.metadata.pythonVersion), pinned: main.pinned,
                        fromIndex: main.fromIndex,
                        interpreter: environment.metadata.sourceInterpreter.map(\.path).flatMap(nonBlank))
        }
    }

    /// `pipx list --json`: every tool, each asked for. R40: pipx exits 1 when a venv is broken (its Python was
    /// removed), and still prints every healthy venv (`Fixtures/pipx/t13-list-json-broken-venv`): those are listed,
    /// and the broken ones become the engine's `note`. Only output pipx can't use fails the listing, in its words.
    public func listInstalled() async throws -> [Package] {
        try await listVenvs().map { venv in
            Package(id: ref(venv.name), displayName: venv.name, installedVersion: venv.version,
                    installedOnRequest: true)
        }
    }

    private func listVenvs() async throws -> [Venv] {
        let result = try await tool.run(["list", "--json"])
        let answer: ListAnswer
        if result.exitCode == 0 {
            answer = try tool.decode(ListAnswer.self, from: result.stdout)
            state.broken(nil)
        } else {
            guard let healthy = try? tool.decode(ListAnswer.self, from: result.stdout) else {
                state.broken(nil)
                throw tool.failure("pipx list failed", result)
            }
            answer = healthy
            // `--json` says nothing about the broken ones; the text listing names each on stderr.
            let named = try? await tool.run(["list", "--short"])
            state.broken(Self.brokenNote(stderr: named?.stderr ?? ""))
        }
        let venvs = Self.venvs(answer)
        state.listed(venvs)
        return venvs
    }

    /// R40's note: how many tools a broken venv kept out of the listing, from the lines `pipx list` prints on stderr
    /// for each (`package cowsay has invalid interpreter …`, `t13-list-short-broken-venv-stderr.txt`), and that Repair
    /// tools (`pipx reinstall-all`) fixes them. Without such a line pipx only said something is wrong (it exited
    /// non-zero), so the note says no more than that.
    static func brokenNote(stderr: String) -> String {
        let count = stderr.split(whereSeparator: \.isNewline)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package ") }.count
        switch count {
        case 0: return "pipx reported a problem. Tools that answered are listed; Repair tools may fix it."
        case 1: return "1 pipx tool is broken. Repair tools fixes it."
        default: return "\(count) pipx tools are broken. Repair tools fixes them."
        }
    }

    // MARK: outdated

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// pipx 1.15.1 and later check for themselves; an older pipx (as `detect()` found it) is checked against PyPI.
    /// Either way, a tool that couldn't be checked is named in `unchecked` (R6) and the others still count.
    public func checkOutdated() async throws -> OutdatedReport {
        if let version = state.version,
           EcosystemVersion.compare(version, Self.outdatedCheckVersion, scheme: .pep440) == .orderedAscending {
            return try await outdatedFromPyPI()
        }
        return try await outdatedFromPipx()
    }

    /// `pipx list --outdated --output json`'s answer.
    struct OutdatedAnswer: Decodable {
        struct Entry: Decodable, Equatable {
            /// The venv; `package` (not read) is its PyPI name.
            let environment: String
            let version: String?
            let latestVersion: String?
            let injected: Bool?
            let pinned: Bool?

            enum CodingKeys: String, CodingKey {
                case environment, version, injected, pinned
                case latestVersion = "latest_version"
            }
        }

        struct Payload: Decodable {
            let packages: [Entry]?
            let packagesChecked: Int?

            enum CodingKeys: String, CodingKey {
                case packages
                case packagesChecked = "packages_checked"
            }
        }

        /// One venv pipx couldn't check, or (no environment) the whole command failing.
        struct Failure: Decodable {
            let code: String?
            let environment: String?
            let message: String?
        }

        /// "success", "partial" or "error".
        let status: String?
        let data: Payload?
        let errors: [Failure]?
    }

    /// pipx exits 1 when any venv couldn't be checked; the JSON on stdout still has the others.
    private func outdatedFromPipx() async throws -> OutdatedReport {
        let result = try await tool.run(["list", "--outdated", "--output", "json"])
        guard result.exitCode == 0 || result.exitCode == 1,
              let answer = try? JSONDecoder().decode(OutdatedAnswer.self, from: Data(result.stdout.utf8)) else {
            // An older pipx refuses the flags; pipx stopped before any JSON: its own words are on stderr.
            throw tool.failure("pipx list --outdated failed", result)
        }
        return try Self.outdated(answer)
    }

    /// The updates in pipx's answer. Tools pipx couldn't check are left out and named in `unchecked` (an error
    /// without a venv makes it say some weren't named); only when none could be checked is the whole check a failure,
    /// in pipx's words.
    static func outdated(_ answer: OutdatedAnswer) throws -> OutdatedReport {
        let packages = answer.data?.packages ?? []
        let errors = answer.errors ?? []
        if packages.isEmpty, let first = errors.first {
            let failed = Set(errors.compactMap(\.environment))
            let checked = answer.data?.packagesChecked ?? 0
            let wholeCommand = errors.contains { $0.environment == nil }
            if answer.status == "error" || wholeCommand || failed.count >= checked {
                throw EngineError(engine: .pipx, message: "pipx list --outdated failed\(code(first)): "
                                  + text(first).prefix(300))
            }
        }
        var reasons: [String: String] = [:]
        for error in errors {
            guard let environment = error.environment else { continue }
            reasons[environment] = reasons[environment] ?? String(text(error).prefix(300))
        }
        let unchecked = UncheckedPackages(reasons: reasons, unnamed: errors.contains { $0.environment == nil })
        return OutdatedReport(packages: updates(packages), unchecked: unchecked)
    }

    /// ` (code)` for a pipx error with a code.
    private static func code(_ failure: OutdatedAnswer.Failure) -> String {
        nonBlank(failure.code).map { " (\($0))" } ?? ""
    }

    /// A pipx error's message on one line, without URL credentials.
    private static func text(_ failure: OutdatedAnswer.Failure) -> String {
        CredentialScrubber.scrub(failure.message ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The rows pipx reported that are real updates, by PEP 440: never a pinned tool or an injected package (`pipx
    /// upgrade <venv>` moves neither), never a downgrade or a pre-release for a stable install.
    static func updates(_ entries: [OutdatedAnswer.Entry]) -> [Package] {
        entries.compactMap { entry in
            guard entry.injected != true, entry.pinned != true, let installed = nonBlank(entry.version),
                  let latest = nonBlank(entry.latestVersion),
                  let newer = EcosystemVersion.newerVersion(than: installed, among: [latest], scheme: .pep440)
            else { return nil }
            return Package(id: PackageRef(engine: .pipx, kind: .tool, name: entry.environment),
                           displayName: entry.environment, installedVersion: installed, latestVersion: newer)
        }.sorted { $0.id.name < $1.id.name }
    }

    // MARK: outdated (PyPI, for a pipx before 1.15.1)

    /// Each tool's project looked up on PyPI, a few at a time. A lookup that fails (no such project, too large,
    /// offline) leaves that tool out, named in `unchecked`; when every one fails, the check fails.
    private func outdatedFromPyPI() async throws -> OutdatedReport {
        let venvs = try await listVenvs()
        let names = Self.pypiNames(venvs)
        guard !names.isEmpty else { return OutdatedReport(packages: []) }
        return try Self.pypiUpdates(venvs, projects: try await PyPI.projects(names, for: .pipx, from: registry))
    }

    /// A venv the PyPI check covers: not pinned, installed by name from an index.
    private static func checksOnPyPI(_ venv: Venv) -> Bool { !venv.pinned && venv.fromIndex }

    /// The PEP 503 names to look up for `venvs`, each once, sorted.
    static func pypiNames(_ venvs: [Venv]) -> [String] {
        Set(venvs.filter(checksOnPyPI).map { PackageNameRules.normalizedPythonName($0.project) }).sorted()
    }

    /// The updates PyPI's answers give `venvs` (keyed by PEP 503 name): each one's newest release that isn't yanked
    /// and fits its Python, and never a pre-release: `pipx upgrade` runs pip without `--pre`, and BrewxPort doesn't
    /// read the pip arguments a venv was made with, so it offers only what the upgrade would install. A venv whose
    /// lookup failed is in `unchecked`. Throws when there was something to check and no answer came back.
    static func pypiUpdates(_ venvs: [Venv], projects: [String: Result<PyPI.Project, any Error>]) throws
        -> OutdatedReport {
        var rows: [Package] = []
        let unchecked = try OutdatedLookups.tally(
            venvs.filter(checksOnPyPI), answers: projects, key: { PackageNameRules.normalizedPythonName($0.project) },
            name: \.name, noAnswer: { $0.map { PyPI.noAnswer($0, for: .pipx) } }
        ) { venv, project in
            guard let installed = venv.version,
                  let newer = project.newerVersion(than: installed, python: venv.python, stableOnly: true)
            else { return }
            rows.append(Package(id: PackageRef(engine: .pipx, kind: .tool, name: venv.name), displayName: venv.name,
                                installedVersion: installed, latestVersion: newer))
        }
        return OutdatedReport(packages: rows.sorted { $0.id.name < $1.id.name }, unchecked: unchecked)
    }

    /// Whether an install spec (`package_or_url`) named `project` on an index (`black`, `black==24.2.0`,
    /// `Black[d]>=24`), rather than a URL, a path, an archive or a git repository, which pipx doesn't check.
    static func isIndexSpec(_ spec: String, project: String) -> Bool {
        let text = spec.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first != ".", first != "~", !text.contains("/"), !text.contains("\\"),
              !text.contains("@") else { return false }
        let name = text.prefix { !"[=<>!~;, (".contains($0) }
        return PackageNameRules.normalizedPythonName(String(name)) == PackageNameRules.normalizedPythonName(project)
    }

    // MARK: search

    /// PyPI has no search, so the query is looked up as an exact project name (`PyPI.search`). The row is keyed by
    /// the PEP 503 name, which pipx names a venv by.
    public func search(_ query: String) async throws -> [Package] {
        try await PyPI.search(query, for: .pipx, from: registry)
    }

    // MARK: info

    /// The venv's project on PyPI: its summary, home page and newest release.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .pipx, ref.kind == .tool else {
            throw EngineError(engine: .pipx, message: "Package belongs to a different engine")
        }
        return try await PyPI.details(ref, project: state.project(of: ref.name) ?? ref.name, from: registry)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// `pipx uninstall` takes one venv, and so does `pipx upgrade` before pipx 1.6.0; a step per tool also gives each
    /// upgrade its own result.
    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? {
        operation == .upgrade || operation == .remove ? 1 : nil
    }

    /// `install` with PyPI project names, `upgrade` and `uninstall` with venv names, one per command for those two
    /// (`maxTargetsPerCommand`).
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard !refs.isEmpty else { throw EngineError(engine: .pipx, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .pipx && $0.kind == .tool }) else {
            throw EngineError(engine: .pipx, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .pipx, message: "pipx installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .pipx, message: "pipx has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .pipx, message: "pipx commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .pipx)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .pipx) }
        try requireTargetLimit(refs, for: op)
        let names = refs.map(\.name)
        switch op {
        case .install: return try tool.command(["install"] + names)
        case .upgrade: return try tool.command(["upgrade"] + names)
        case .remove: return try tool.command(["uninstall"] + names)
        case .repair:
            throw EngineError(engine: .pipx, message: "pipx repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .pipx, message: "pipx can't mark packages")
        }
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .pipx, kind: .tool, name: name) }

    /// What the last `detect()` and `pipx list` found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedVersion: String?
        private var detectedHome: URL?
        private var detectedBin: URL?
        /// Venv name → its PyPI project.
        private var projects: [String: String] = [:]

        var version: String? { lock.withLock { detectedVersion } }
        var home: URL? { lock.withLock { detectedHome } }
        var bin: URL? { lock.withLock { detectedBin } }

        func detected(version: String?, home: URL?, bin: URL?) {
            lock.withLock {
                detectedVersion = version
                detectedHome = home
                detectedBin = bin
            }
        }

        func listed(_ venvs: [Venv]) {
            let map = Dictionary(venvs.map { ($0.name, $0.project) }) { first, _ in first }
            lock.withLock { projects = map }
        }

        func project(of venv: String) -> String? { lock.withLock { projects[venv] } }

        /// What the last listing said about broken venvs (R40); nil when there were none.
        var note: String? { lock.withLock { brokenNote } }
        private var brokenNote: String?

        func broken(_ note: String?) { lock.withLock { brokenNote = note } }
    }
}

extension PipxEngine.ListAnswer.MainPackage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case package, pinned
        case packageVersion = "package_version"
        case packageOrURL = "package_or_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let project = try container.decode(String.self, forKey: .package)
        package = project
        packageVersion = try container.decodeIfPresent(String.self, forKey: .packageVersion)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        // Read, judged and dropped: the spec can hold an index URL with a token.
        let spec = try container.decodeIfPresent(String.self, forKey: .packageOrURL)
        fromIndex = spec.map { PipxEngine.isIndexSpec($0, project: project) } ?? true
    }
}

// MARK: Task 10: runtime and repair

extension PipxEngine: RuntimeReporting, ToolRepairing {
    /// The Homebrew Pythons pipx's venvs may run on (`homebrewPythons`), each with its tools, from a fresh `pipx list
    /// --json`, and which of them survive a patch update (R29): each venv's `pyvenv.cfg` (in PIPX_HOME's `venvs`)
    /// names the Python's folder as it was made. A broken venv (its Python already gone) isn't in the listing (R40):
    /// no runtime update can break it further. Throws when pipx can't list.
    public func runtimeUses() async throws -> [RuntimeUse] {
        let venvs = try await listVenvs()
        let folder = state.home?.appendingPathComponent("venvs", isDirectory: true)
        let homes = Dictionary(venvs.map { venv in
            // A name that isn't one plain folder name isn't used in a path: its venv counts as unknown.
            (venv.name, VenvConfig.isPlainFolderName(venv.name)
                ? folder.flatMap { venvHome($0.appendingPathComponent(venv.name, isDirectory: true)) } : nil)
        }) { first, _ in first }
        return Self.uses(venvs.map { ($0.name, $0.homebrewPythons, homes[$0.name] ?? nil) })
    }

    /// The `home` in `venv`'s `pyvenv.cfg`; nil when it can't be read.
    private func venvHome(_ venv: URL) -> String? {
        guard let data = try? readToolFile(venv.appendingPathComponent("pyvenv.cfg").path) else { return nil }
        return VenvConfig.home(String(decoding: data, as: UTF8.self))
    }

    /// One use per formula, each with its tools and the ones whose `home` follows its patch updates, sorted. A tool
    /// whose `home` was read and isn't Homebrew's (`VenvConfig.isHomebrew`) runs on no Homebrew Python, so it uses none
    /// (R29); one whose `home` couldn't be read keeps the formulae its interpreter and version name (the careful way).
    static func uses(_ tools: [(name: String, formulae: [String], home: String?)]) -> [RuntimeUse] {
        var byFormula: [String: (tools: [String], safe: [String])] = [:]
        for tool in tools {
            if let home = tool.home, !VenvConfig.isHomebrew(home: home) { continue }
            for formula in tool.formulae {
                byFormula[formula, default: ([], [])].tools.append(tool.name)
                if let home = tool.home, VenvConfig.followsPatchUpdates(home: home, formula: formula) {
                    byFormula[formula, default: ([], [])].safe.append(tool.name)
                }
            }
        }
        return byFormula.keys.sorted().map {
            RuntimeUse(formula: $0, tools: byFormula[$0]!.tools.sorted(), patchSafeTools: byFormula[$0]!.safe.sorted())
        }
    }

    /// `pipx reinstall-all`: every venv at once, with pipx's default Python, so `tools` doesn't matter.
    public func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        try access.requireWritable(for: .repair, engine: .pipx)
        return [RepairCommand(tool: nil, spec: try tool.command(["reinstall-all"]))]
    }

    /// None: `pipx reinstall-all` takes every venv.
    public func repairRefusals(for tools: [String]) -> [String: String] { [:] }
}
