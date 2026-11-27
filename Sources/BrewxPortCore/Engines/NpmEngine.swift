import Foundation

/// npm's global packages: the command-line tools installed with `npm install -g`, driven through `npm` and its `--json`
/// output. Always as the user, never as root (Plan 9). Found from the login shell's PATH first (nvm, fnm, asdf…), then
/// the fixed folders (`fixedFolders`).
///
/// Globals not from the registry (R14, `Fixtures/npm/nonregistry-*`): one installed from a folder or with `npm link`
/// (`resolved: file:…` in the listing) is listed but never offered as an update or upgraded by name, which would
/// replace it with the registry's package of that name; git, GitHub and tarball installs look like registry ones to
/// npm, so npm's own outdated check decides for them. An entry npm lists without a version (a dangling GitHub install)
/// is listed with its version unknown, and isn't offered. The update check doesn't depend on that listing (R26): when
/// it fails, npm's own outdated answer still counts (it leaves folder and linked installs out itself), with a note, as
/// updates held back from every update: upgrades are refused until a listing works again.
public struct NpmEngine: Engine, InstallLocationReporting {
    public let id: EngineID = .npm
    public let capabilities: EngineCapabilities = [.jsonOutput]

    /// BrewxPort's npm settings for every command: no "a new npm is available" notice, no funding or audit messages.
    /// Variables, not flags, because npm 12 refuses flags it doesn't know.
    public static let settings = [
        "npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false",
    ]

    /// The globals that came with Node itself, under any Node (Homebrew's, nvm's, the installer's). They stay listed,
    /// and their updates keep the usual rules, but they're never removed: `npm uninstall -g npm` deletes Node's own
    /// npm, which BrewxPort can't put back.
    public static let cameWithNode: Set<String> = ["npm", "corepack"]

    /// The packages Homebrew's `node` formula ships and updates with node; never offered as updates under it.
    static let bundledWithHomebrewNode = cameWithNode

    /// Why a global that came with Node stays, for the uninstall sheet ("npm stays: it came with Node; …").
    public static func cameWithNodeReason(_ name: String) -> String {
        "it came with Node; removing it would break Node's own \(name)."
    }

    /// Why npm is read-only under Volta, which keeps track of the tools itself: `npm install -g` goes into Volta's own
    /// store, and `npm ls -g` doesn't show what's there.
    public static let voltaReason = "Volta manages these tools. Use volta install and volta uninstall."

    /// Whether this npm is Volta's: it's in Volta's folder (`~/.volta`), or it resolves to Volta's shim
    /// (`volta-shim`, which every Volta command links to), as with a VOLTA_HOME elsewhere. `realPath` is realpath(3);
    /// tests pass their own.
    public static func isVolta(npm: URL, home: String, realPath: (String) -> String? = ToolLocator.realPath) -> Bool {
        let folder = home + "/.volta/"
        if npm.path.hasPrefix(folder) { return true }
        guard let real = realPath(npm.path) else { return false }
        return real.hasPrefix(folder) || (real as NSString).lastPathComponent == "volta-shim"
    }

    /// Where Homebrew's `node` lives: its Apple silicon prefix, or Intel Homebrew's Cellar and opt links.
    static let homebrewPrefixes = ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/"]

    private let tool: LanguageTool
    private let state = State()
    private let homebrewNode: @Sendable (URL) -> Bool
    private let nodeFormula: @Sendable (URL) -> String?
    private let voltaNpm: @Sendable (URL) -> Bool
    private let access: InstallAccessState
    private let home: String

    public var executableURL: URL? { tool.executable }

    /// npm's global prefix (`npm prefix -g`) as the last `detect()` read it: where global packages go.
    public var installLocation: URL? { state.prefix }

    /// The prefix's `bin` folder, where npm links global packages' commands.
    public var binLocation: URL? { state.prefix?.appendingPathComponent("bin", isDirectory: true) }

    /// Why this account can't change npm's globals: the last detect found the prefix's `lib/node_modules` or `bin`
    /// not writable (Node from nodejs.org or MacPorts). Nil otherwise.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// The app's npm: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `base` is the
    /// environment every command starts from. `homebrewNode` says whether Homebrew's node formula owns an npm, and
    /// `nodeFormula` which formula (`homebrewNodeFormula`); `isVolta` whether it's Volta's (`isVolta(npm:home:)`,
    /// when nil); `isWritable` is the access check (`InstallAccess`).
    public init(runner: CommandRunning, loginShell: @escaping LoginShellContextProvider, arch: Arch = .current,
                base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                homebrewNode: @escaping @Sendable (URL) -> Bool = NpmEngine.isHomebrewNode(npm:),
                nodeFormula: @escaping @Sendable (URL) -> String? = { NpmEngine.homebrewNodeFormula(npm: $0) },
                isVolta: (@Sendable (URL) -> Bool)? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .npm, name: "npm", runner: runner, settings: Self.settings, base: base,
                            loginShell: loginShell, fixedFolders: folders)
        self.homebrewNode = homebrewNode
        self.nodeFormula = nodeFormula
        voltaNpm = isVolta ?? { Self.isVolta(npm: $0, home: home) }
        access = InstallAccessState(isWritable: isWritable)
        self.home = home
    }

    /// npm at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed. Its
    /// folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, executable: URL?, captured: [String: String] = [:],
                base: [String: String] = ProcessRunner.baseEnvironment,
                homebrewNode: @escaping @Sendable (URL) -> Bool = NpmEngine.isHomebrewNode(npm:),
                nodeFormula: @escaping @Sendable (URL) -> String? = { NpmEngine.homebrewNodeFormula(npm: $0) },
                isVolta: (@Sendable (URL) -> Bool)? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true }) {
        tool = LanguageTool(engine: .npm, name: "npm", runner: runner, executable: executable, captured: captured,
                            settings: Self.settings, base: base)
        self.homebrewNode = homebrewNode
        self.nodeFormula = nodeFormula
        let home = LanguageTool.home(base)
        voltaNpm = isVolta ?? { Self.isVolta(npm: $0, home: home) }
        access = InstallAccessState(isWritable: isWritable)
        self.home = home
    }

    // MARK: finding npm

    /// Where npm is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first),
    /// MacPorts', nvm's default version (`nvmDefaultBin`, in `NVM_DIR` or `~/.nvm`), fnm's default alias, then asdf's
    /// and mise's shims (they pick a Node version by folder, which is why commands run from the home folder).
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        var folders: [String] = arch == .arm64 ? ["/opt/homebrew/bin", "/usr/local/bin"]
                                               : ["/usr/local/bin", "/opt/homebrew/bin"]
        folders.append("/opt/local/bin")
        if let nvm = nvmDefaultBin(nvmDir: captured["NVM_DIR"] ?? home + "/.nvm") { folders.append(nvm) }
        folders += [
            home + "/.local/share/fnm/aliases/default/bin",
            home + "/.asdf/shims",
            home + "/.local/share/mise/shims",
        ]
        return folders
    }

    /// The bin folder of nvm's default Node (`nvm alias default …`, saved in `alias/default`). The alias names a
    /// version (`v22.11.0`) or the start of one (`22`, `22.11`), or it's `node` or `stable` (the newest); the newest
    /// installed version that matches wins. nil for any other alias (`lts/*`), or when nothing installed matches.
    static func nvmDefaultBin(nvmDir: String) -> String? {
        guard let alias = try? String(contentsOfFile: nvmDir + "/alias/default", encoding: .utf8) else { return nil }
        let wanted = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let versions = nvmDir + "/versions/node"
        guard let installed = try? FileManager.default.contentsOfDirectory(atPath: versions) else { return nil }
        let matching: [String]
        if wanted == "node" || wanted == "stable" {
            matching = installed
        } else {
            let number = wanted.hasPrefix("v") ? String(wanted.dropFirst()) : wanted
            guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
            matching = installed.filter { $0 == "v" + number || $0.hasPrefix("v" + number + ".") }
        }
        let newest = matching.filter { $0.hasPrefix("v") && EcosystemVersion.isValid($0, scheme: .semver) }
            .max { EcosystemVersion.compare($0, $1, scheme: .semver) == .orderedAscending }
        return newest.map { versions + "/" + $0 + "/bin" }
    }

    /// Whether Homebrew's `node` formula owns this npm, which it then updates with node (with corepack).
    public static func isHomebrewNode(npm: URL) -> Bool {
        isHomebrewNode(npm: npm, realPath: ToolLocator.realPath)
    }

    /// The npm is in Homebrew's Apple silicon prefix, or it or the `node` beside it resolves into Homebrew's Cellar or
    /// opt folders. Intel Homebrew's npm in /usr/local/bin looks just like the nodejs.org installer's; only its node
    /// (a link into the Cellar) tells them apart. `realPath` is realpath(3); tests pass their own.
    static func isHomebrewNode(npm: URL, realPath: (String) -> String?) -> Bool {
        let node = npm.deletingLastPathComponent().appendingPathComponent("node").path
        let paths = [npm.path, realPath(npm.path), realPath(node)].compactMap { $0 }
        return paths.contains { path in homebrewPrefixes.contains { path.hasPrefix($0) } }
    }

    /// The Homebrew formula that owns this npm's Node: the `node` beside npm resolves into its Cellar (npm's own file
    /// resolves into lib/node_modules, which says nothing). Nil for any other Node. `realPath` is realpath(3); tests
    /// pass their own.
    public static func homebrewNodeFormula(npm: URL, realPath: (String) -> String? = ToolLocator.realPath) -> String? {
        let node = npm.deletingLastPathComponent().appendingPathComponent("node").path
        return HomebrewFormula.owning(node, realPath: realPath)
    }

    // MARK: detect

    /// npm's version, then its global prefix (`npm prefix -g`) for `installLocation`, and whether this account can
    /// write the prefix's `lib/node_modules` and `bin`. The prefix is asked once per npm executable: a later detect
    /// that finds the same npm keeps the answer, and one that finds another npm asks again. So does one after a prefix
    /// that wasn't writable, so the official fix (`npm config set prefix`) shows on the next check. A prefix npm
    /// doesn't give leaves npm present, without a location, and is asked again next time. Volta's npm is read-only
    /// whatever its folders say (`voltaReason`).
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { stdout in
            guard let line = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let version = line.trimmingCharacters(in: .whitespaces)
            return EcosystemVersion.isValid(version, scheme: .semver) ? version : nil
        }
        guard case .present(let executable, _) = status else {
            state.prefixRead(nil, for: nil)
            state.runsOn(nil, known: false)
            state.managedByVolta(false)
            access.checked(.npm, folders: [], home: home)
            return status
        }
        state.runsOn(nodeFormula(executable), known: true)
        let volta = voltaNpm(executable)
        state.managedByVolta(volta)
        if state.prefix(for: executable) == nil || access.readOnlyReason != nil {
            var location: URL?
            if let result = try? await tool.run(["prefix", "-g"]), result.exitCode == 0,
               let line = result.stdout.split(whereSeparator: \.isNewline).first {
                let path = line.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { location = URL(fileURLWithPath: path, isDirectory: true) }
            }
            state.prefixRead(location, for: executable)
        }
        let folders = state.prefix.map { [$0.appendingPathComponent("lib/node_modules", isDirectory: true),
                                          $0.appendingPathComponent("bin", isDirectory: true)] } ?? []
        access.checked(.npm, folders: folders, home: home, named: state.prefix)
        if volta { access.readOnly(Self.voltaReason) }
        return status
    }

    // MARK: installed

    private struct Tree: Decodable {
        struct Dependency: Decodable {
            let version: String?
            /// Set for a folder or `npm link` install (`file:…`); read only for that, and never kept.
            let resolved: String?
        }
        let dependencies: [String: Dependency]?
    }

    /// One global package as `npm ls -g` lists it.
    struct Global: Equatable, Sendable {
        let name: String
        /// nil when npm lists none (a dangling GitHub install).
        let version: String?
        /// Installed from a folder or with `npm link` (R14): never offered or upgraded by name.
        let fromFolder: Bool
    }

    /// `npm ls -g --json --depth=0`: every global package, npm itself included. All of them were asked for.
    public func listInstalled() async throws -> [Package] {
        try await listGlobals().map { global in
            Package(id: ref(global.name), displayName: global.name, installedVersion: global.version,
                    installedOnRequest: true)
        }
    }

    /// `npm ls -g`'s globals, sorted by name, remembered for `command(for:)` (R14). A listing that fails is
    /// remembered too: upgrades are refused until one works (R26).
    private func listGlobals() async throws -> [Global] {
        let globals: [Global]
        do {
            globals = Self.globals(try await runJSON(Self.listArguments))
        } catch {
            if !Task.isCancelled { state.listed(nil) }
            throw error
        }
        state.listed(globals)
        return globals
    }

    static let listArguments = ["ls", "-g", "--json", "--depth=0"]

    private static func globals(_ tree: Tree) -> [Global] {
        (tree.dependencies ?? [:]).sorted { $0.key < $1.key }.map { name, dependency in
            Global(name: name, version: nonBlank(dependency.version),
                   fromFolder: dependency.resolved?.hasPrefix("file:") == true)
        }
    }

    // MARK: outdated

    private struct Outdated: Decodable {
        let current: String?
        let latest: String?
    }

    /// What an outdated check says when `npm ls -g` failed (R26).
    static let unlistedNote = "Couldn't read npm's list of globals; folder and linked installs can't be told apart "
        + "until it works"

    /// Why an update waits when `npm ls -g` failed: its upgrade would be refused (R26), so it's never offered.
    static let unlistedHold = UpdateHold(reason: "Updates wait until npm's list of globals can be read.",
                                         blocksAutomatic: true, blocksManual: true)

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// `npm outdated -g --json`, which exits 1 whenever anything is outdated, filtered by `updates`, after a listing
    /// that says which globals came from a folder (never offered, R14). A listing that fails doesn't fail the check
    /// (R26): npm's own answer, which already leaves folder and linked installs out, still counts, with
    /// `unlistedNote`, as updates held back from every update (`unlistedHold`), since their upgrades are refused.
    /// Under Volta nothing is offered and npm isn't asked: Volta updates its tools itself (`voltaReason`).
    public func checkOutdated() async throws -> OutdatedReport {
        guard !state.isVolta else { return OutdatedReport(packages: []) }
        let globals: [Global]?
        do {
            globals = try await listGlobals()
        } catch {
            try Task.checkCancellation()
            globals = nil
        }
        let entries: [String: Outdated] = try await runJSON(["outdated", "-g", "--json"], accepting: [0, 1])
        let rows = entries.sorted { $0.key < $1.key }.map { name, entry in
            Package(id: ref(name), displayName: name, installedVersion: nonBlank(entry.current),
                    latestVersion: nonBlank(entry.latest))
        }
        let homebrewNode = tool.executable.map(homebrewNode) ?? false
        guard let globals else {
            // The updates still count (R26), but their upgrades would be refused: held, with why, never offered.
            let held = Self.updates(rows, homebrewNode: homebrewNode).map {
                HeldUpdate(package: $0, hold: Self.unlistedHold)
            }
            return OutdatedReport(packages: [], unchecked: UncheckedPackages(note: Self.unlistedNote), held: held)
        }
        let offered = Self.notFromFolders(rows, of: globals)
        return OutdatedReport(packages: Self.updates(offered, homebrewNode: homebrewNode))
    }

    /// R14: the rows for globals `globals` doesn't show as installed from a folder or with `npm link`.
    static func notFromFolders(_ rows: [Package], of globals: [Global]) -> [Package] {
        let folders = Set(globals.filter(\.fromFolder).map(\.name))
        return rows.filter { !folders.contains($0.id.name) }
    }

    /// The rows `npm outdated` gave that are real updates. Only `latest` counts (an upgrade installs `name@latest`),
    /// and only when it's newer than what's installed by semver: never a downgrade, a pre-release for a stable
    /// install, or anything for a linked or git install. Under Homebrew's node, npm and corepack are left out:
    /// Homebrew updates them with node.
    static func updates(_ rows: [Package], homebrewNode: Bool) -> [Package] {
        rows.compactMap { row in
            if homebrewNode, bundledWithHomebrewNode.contains(row.id.name) { return nil }
            guard let installed = row.installedVersion, let latest = row.latestVersion,
                  let newer = EcosystemVersion.newerVersion(than: installed, among: [latest], scheme: .semver)
            else { return nil }
            var update = row
            update.latestVersion = newer
            return update
        }
    }

    // MARK: search

    private struct SearchHit: Decodable {
        let name: String
        let version: String?
        let description: String?
    }

    /// `npm search --json --searchlimit=50 -- <query>` (the registry's 50 best matches). A name npm couldn't install
    /// by name is left out.
    public func search(_ query: String) async throws -> [Package] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError(engine: .npm, message: "Search query is empty") }
        let hits: [SearchHit] = try await runJSON(["search", "--json", "--searchlimit=50", "--", text])
        return hits.filter { PackageNameRules.isValid($0.name, for: .npm) }.map { hit in
            Package(id: ref(hit.name), displayName: hit.name, latestVersion: nonBlank(hit.version),
                    summary: nonBlank(hit.description))
        }
    }

    // MARK: info

    /// The fields of `npm view` that details show, the only ones asked for.
    private struct View: Decodable {
        let name: String?
        let version: String?
        let description: String?
        let homepage: String?
    }

    /// npm 11 prints one object; npm 12 always an array.
    private struct ViewAnswer: Decodable {
        let first: View?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let many = try? container.decode([View].self) {
                first = many.first
            } else {
                first = try container.decode(View.self)
            }
        }
    }

    /// What `info` asks `npm view` for: the fields details show (`View`).
    static let viewFields = ["name", "version", "description", "homepage", "--json"]

    /// `npm view <name>@latest … --json`, the latest version's details from the registry npm is set up for.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .npm, ref.kind == .tool else {
            throw EngineError(engine: .npm, message: "Package belongs to a different engine")
        }
        try PackageNameRules.validate(ref.name, for: .npm)
        let answer: ViewAnswer = try await runJSON(["view", "\(ref.name)@latest"] + Self.viewFields)
        guard let view = answer.first, let name = nonBlank(view.name), let version = nonBlank(view.version) else {
            throw EngineError(engine: .npm, message: "npm had no information for \(ref.name)")
        }
        return PackageDetails(ref: ref, summary: nonBlank(view.description), homepage: webURL(view.homepage),
                              latestVersion: version, reportedName: name)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// `install -g`, `install -g name@latest` (never `update -g`, which downgrades a package newer than `latest`), and
    /// `uninstall -g`, for registry names only. An upgrade is only for globals the last listing showed, and not from a
    /// folder (`upgradable`, R14). A removal is never of npm or corepack, which came with Node (`cameWithNode`).
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard !refs.isEmpty else { throw EngineError(engine: .npm, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .npm && $0.kind == .tool }) else {
            throw EngineError(engine: .npm, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .npm, message: "npm installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .npm, message: "npm has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .npm, message: "npm commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .npm)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .npm) }
        let names = refs.map(\.name)
        switch op {
        case .install: return try tool.command(["install", "-g"] + names)
        case .upgrade:
            try upgradable(names)
            return try tool.command(["install", "-g"] + names.map { $0 + "@latest" })
        case .remove:
            if let kept = names.first(where: Self.cameWithNode.contains) {
                throw EngineError(engine: .npm, message: "\(kept) came with Node; removing it would break Node's own "
                                  + "\(kept).")
            }
            return try tool.command(["uninstall", "-g"] + names)
        case .repair:
            throw EngineError(engine: .npm, message: "npm repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .npm, message: "npm can't mark packages")
        }
    }

    /// R14: refuses, with a one-line reason that never shows the folder, an upgrade of a global the last listing (the
    /// installed list or an outdated check) showed came from a folder or `npm link`, and of one it didn't show at all.
    /// R26: when the last listing failed, every upgrade is refused.
    private func upgradable(_ names: [String]) throws {
        let listed = state.globals
        for name in names {
            guard !state.listFailed else {
                throw EngineError(engine: .npm, message: "BrewxPort couldn't read npm's list of global packages, so "
                                  + "it doesn't update \(name).")
            }
            guard let global = listed?[name] else {
                throw EngineError(engine: .npm, message: "BrewxPort can't find \(name) among npm's global packages, "
                                  + "so it doesn't update it.")
            }
            guard !global.fromFolder else {
                throw EngineError(engine: .npm, message: "\(name) was installed from a folder on this Mac, so "
                                  + "BrewxPort doesn't update it.")
            }
        }
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .npm, kind: .tool, name: name) }

    /// The error npm prints to stdout with `--json`: `{"error": {"code": …, "summary": …, "detail": …}}`. A package
    /// named "error" in `npm outdated`'s answer has neither a code nor a summary, so it isn't one.
    private struct ErrorAnswer: Decodable {
        struct Report: Decodable {
            let code: String?
            let summary: String?
        }
        let error: Report?
    }

    /// npm's `--json` answer to `arguments`. An error object is a failure in npm's own words (its code and summary,
    /// without URL credentials, never stderr's stack trace and log path), whatever the exit code; otherwise only an
    /// exit code in `accepting` counts.
    private func runJSON<T: Decodable>(_ arguments: [String], accepting codes: Set<Int32> = [0]) async throws -> T {
        let result = try await tool.run(arguments)
        let command = "npm " + (arguments.first ?? "")
        if let report = (try? JSONDecoder().decode(ErrorAnswer.self, from: Data(result.stdout.utf8)))?.error,
           let text = (nonBlank(report.summary) ?? nonBlank(report.code)).map(CredentialScrubber.scrub) {
            let code = nonBlank(report.code).map { " (\($0))" } ?? ""
            throw EngineError(engine: .npm, message: "\(command) failed\(code): \(text.prefix(300))")
        }
        guard codes.contains(result.exitCode) else { throw tool.failure("\(command) failed", result) }
        do {
            return try tool.decode(T.self, from: result.stdout)
        } catch where result.exitCode != 0 {
            // An accepted non-zero exit (outdated's 1) without an answer: npm stopped first and said why on stderr.
            throw tool.failure("\(command) failed", result)
        }
    }

    /// What the last `detect()` and listing found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        /// The global prefix, and the npm that gave it.
        private var prefixAnswer: (executable: URL, prefix: URL)?
        private var listing: [String: Global]?

        var prefix: URL? { lock.withLock { prefixAnswer?.prefix } }

        /// The prefix `executable` gave; nil when it gave none, or another npm did.
        func prefix(for executable: URL) -> URL? {
            lock.withLock { prefixAnswer?.executable == executable ? prefixAnswer?.prefix : nil }
        }

        /// What `executable` said its prefix is; nil for either forgets it.
        func prefixRead(_ prefix: URL?, for executable: URL?) {
            lock.withLock { prefixAnswer = executable.flatMap { npm in prefix.map { (npm, $0) } } }
        }

        /// The last listing's globals by name; nil before one, and when the last one failed.
        var globals: [String: Global]? { lock.withLock { listing } }
        /// The last listing failed.
        var listFailed: Bool { lock.withLock { failed } }
        private var failed = false

        /// A listing's globals; nil: it failed.
        func listed(_ found: [Global]?) {
            let map = found.map { Dictionary($0.map { ($0.name, $0) }) { first, _ in first } }
            lock.withLock {
                listing = map
                failed = map == nil
            }
        }

        /// The Homebrew formula that owns npm's Node, as the last detect found it; nil for any other Node.
        var formula: String? { lock.withLock { nodeFormula } }
        private var nodeFormula: String?
        /// The last detect found npm working, so `formula` says which Node it runs on (nil: not Homebrew's). False
        /// before a detect, and after one that didn't: then nobody can say.
        var runtimeKnown: Bool { lock.withLock { knownRuntime } }
        private var knownRuntime = false

        func runsOn(_ formula: String?, known: Bool) {
            lock.withLock {
                nodeFormula = formula
                knownRuntime = known
            }
        }

        /// The last detect found Volta's npm.
        var isVolta: Bool { lock.withLock { volta } }
        private var volta = false

        func managedByVolta(_ found: Bool) { lock.withLock { volta = found } }
    }
}

// MARK: Task 10: runtime, repair, commands

extension NpmEngine: RuntimeReporting, ToolRepairing, ExecutableNaming {
    /// Homebrew's Node formula when it owns this npm, as the last detect found it: a Node major update needs every
    /// global with native code rebuilt. Throws when no detect found npm working (none yet, or `npm --version` failed,
    /// as when Node can't load): which Node it runs on is unknown, and the caller then holds the update (R29's careful
    /// reading), rather than taking it as "none".
    public func runtimeUses() async throws -> [RuntimeUse] {
        guard state.runtimeKnown else {
            throw EngineError(engine: .npm, message: "BrewxPort couldn't tell which Node npm runs on.")
        }
        return state.formula.map { [RuntimeUse(formula: $0)] } ?? []
    }

    /// R39: `npm rebuild -g <names>`, one command for every registry global the last listing showed (`rebuildNames`),
    /// so `tools` doesn't matter. Plain `npm rebuild -g` fails on Homebrew's Node, whose `bin/npm` is Homebrew's link
    /// (`Fixtures/npm/t13-npm11-rebuild-g`: EEXIST); naming the packages works (`t13-npm11-rebuild-g-named`). Throws
    /// when there's no listing to name them from, or nothing in it to rebuild.
    public func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        try access.requireWritable(for: .repair, engine: .npm)
        guard !state.listFailed, let globals = state.globals else {
            throw EngineError(engine: .npm, message: "BrewxPort couldn't read npm's list of global packages, so it "
                              + "doesn't rebuild them.")
        }
        let names = Self.rebuildNames(Array(globals.values))
        guard !names.isEmpty else {
            throw EngineError(engine: .npm, message: "npm has no global packages BrewxPort can rebuild.")
        }
        return [RepairCommand(tool: nil, spec: try tool.command(["rebuild", "-g"] + names))]
    }

    /// The globals Repair names, sorted: each one npm lists with a version, under a name npm installs by, and not
    /// installed from a folder or with `npm link` (R14), nor npm or corepack, which came with Node (and whose rebuild
    /// is what fails).
    static func rebuildNames(_ globals: [Global]) -> [String] {
        globals.filter { global in
            global.version != nil && !global.fromFolder && !cameWithNode.contains(global.name)
                && PackageNameRules.isValid(global.name, for: .npm)
        }.map(\.name).sorted()
    }

    /// None: Repair names every global it can rebuild in its one command.
    public func repairRefusals(for tools: [String]) -> [String: String] { [:] }

    /// The commands a global's own package.json declares, under the prefix the last detect found.
    public func executables(of name: String) -> [String]? {
        guard PackageNameRules.isValid(name, for: .npm), let prefix = state.prefix else { return nil }
        let folder = prefix.appendingPathComponent("lib/node_modules", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        return NodePackageExecutables.read(packageFolder: folder, name: name)
    }
}
