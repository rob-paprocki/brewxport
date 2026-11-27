import Foundation

/// Bun's global packages: the command-line tools installed with `bun add -g`, driven through `bun`. Always as the
/// user, never as root (Plan 9). Found from the login shell's PATH first, then the fixed folders (`fixedFolders`).
///
/// - Every Bun copy shares one global folder, which Bun picks from its login-shell variables (`BUN_INSTALL_GLOBAL_DIR`,
///   `BUN_INSTALL`, `XDG_CACHE_HOME`) or `~/.bunfig.toml`; commands get those variables, so BrewxPort works on the
///   folder Terminal's Bun does.
/// - Bun has no JSON output for its lists, so its text is read, pinned to the captured output in `Fixtures/bun`: `pm ls
///   -g` (`globals`) and `outdated -g`'s table (`outdatedRows`).
/// - Bun 1.4.5 is the oldest Bun BrewxPort drives (R15): the version those outputs and `outdated -g` were captured and
///   confirmed with. An older Bun is installed but unsupported (`EngineStatus.unsupported`), with a reason saying how
///   to update it (`unsupportedReason`), and nothing is listed, checked or run with it. Nor is anything before Bun's
///   version is known: a query asks it first, and a command is refused until a detect has read it.
/// - Outdated packages come from Bun itself (`outdated -g`), which knows the registry Bun is set up for.
/// - Discover reads the npm registry's search, which Bun has no command for; details come from `bun info`.
/// - Only the `latest` version counts, and an upgrade is `update -g --latest`, which moves to it. Bun's default for
///   dependency install scripts stays: they run only for packages on Bun's built-in trusted list or ones the user
///   trusted. BrewxPort never passes `--trust`.
/// - A global installed from git, a folder or a tarball shows that source in `pm ls -g`, which can hold a token. It's
///   never kept, logged or shown: the row has no version. It's listed and can be removed, but never offered as an
///   update or upgraded (R13): by name, it would become the registry's package of that name.
public struct BunEngine: Engine, InstallLocationReporting {
    public let id: EngineID = .bun
    /// No JSON output: `pm ls -g` and `outdated -g` print text.
    public let capabilities: EngineCapabilities = []

    /// The oldest Bun BrewxPort drives (R15): the version its outputs were captured with, and the one `outdated -g`
    /// is confirmed in. Older Buns print another `pm ls -g` header, and may not read the global folder for `-g`.
    static let minimumVersion = "1.4.5"
    /// Results asked for from the npm registry's search.
    static let searchSize = 50

    static let listArguments = ["pm", "ls", "-g"]
    static let binArguments = ["pm", "bin", "-g"]
    static let outdatedArguments = ["outdated", "-g"]

    private let tool: LanguageTool
    private let registry: any RegistryFetching
    private let state = State()
    private let access: InstallAccessState
    private let home: String

    public var executableURL: URL? { tool.executable }

    /// Why this account can't change Bun's globals: the last detect found its global folder or its bin folder not
    /// writable.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// Bun's global folder (the header of `pm ls -g`) as the last `detect()` read it: where global packages go.
    public var installLocation: URL? { state.globalDirectory }

    /// The folder Bun links global packages' executables into (`pm bin -g`) as the last `detect()` read it.
    public var binLocation: URL? { state.binDirectory }

    /// The app's Bun: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `registry`
    /// reads the npm registry; `base` is the environment every command starts from.
    public init(runner: CommandRunning, registry: any RegistryFetching, loginShell: @escaping LoginShellContextProvider,
                arch: Arch = .current, base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .bun, name: "bun", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        self.home = home
    }

    /// Bun at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed. Its
    /// folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, registry: any RegistryFetching, executable: URL?,
                captured: [String: String] = [:], base: [String: String] = ProcessRunner.baseEnvironment,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true }) {
        tool = LanguageTool(engine: .bun, name: "bun", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.registry = registry
        access = InstallAccessState(isWritable: isWritable)
        home = LanguageTool.home(base)
    }

    // MARK: finding bun

    /// Where Bun is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first),
    /// MacPorts', nanobrew's, the official installer's (BUN_INSTALL's bin, then `~/.bun/bin`), then the version
    /// managers' shims (asdf, mise, proto).
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        var folders: [String] = arch == .arm64 ? ["/opt/homebrew/bin", "/usr/local/bin"]
                                               : ["/usr/local/bin", "/opt/homebrew/bin"]
        folders += ["/opt/local/bin", "/opt/nanobrew/prefix/bin"]
        if let install = captured["BUN_INSTALL"] { folders.append(install + "/bin") }
        folders.append(home + "/.bun/bin")
        folders += [home + "/.asdf/shims", home + "/.local/share/mise/shims", home + "/.proto/shims"]
        return folders
    }

    // MARK: detect

    /// Bun's version, then its executables' folder and its global folder; a folder Bun doesn't give leaves Bun present,
    /// without it. A Bun older than `minimumVersion` is unsupported, with `unsupportedReason`, and isn't asked anything
    /// else (its sidebar row says "Too old", and its page shows the reason).
    public func detect() async -> EngineStatus {
        var status = await tool.detect(["--version"]) { Self.version($0) }
        var version: String?
        var bin: URL?
        var global: URL?
        var globals: [Global]?
        if case .present(let path, let found) = status, !Self.isSupported(found) {
            version = found
            status = .unsupported(path: path, version: found, reason: Self.unsupportedReason(found))
        } else if case .present(_, let found) = status {
            version = found
            if let result = try? await tool.run(Self.binArguments), result.exitCode == 0,
               let line = result.stdout.split(whereSeparator: \.isNewline).first {
                let path = line.trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") { bin = URL(fileURLWithPath: path, isDirectory: true) }
            }
            if let result = try? await tool.run(Self.listArguments), result.exitCode == 0 {
                if let header = result.stdout.split(whereSeparator: \.isNewline).first,
                   let path = Self.globalFolder(header) {
                    global = URL(fileURLWithPath: path, isDirectory: true)
                }
                globals = try? Self.globals(result.stdout)
            }
        }
        state.detected(version: version, globalDirectory: global, binDirectory: bin)
        state.listed(globals)
        access.checked(.bun, folders: [global, bin].compactMap { $0 }, home: home)
        return status
    }

    /// `bun --version`'s first line, `1.4.5`, when it's a semver version.
    static func version(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let version = line.trimmingCharacters(in: .whitespaces)
        return EcosystemVersion.isValid(version, scheme: .semver) ? version : nil
    }

    /// Whether BrewxPort drives this Bun: `minimumVersion` or later, by semver (a 1.4.5 pre-release is older).
    static func isSupported(_ version: String) -> Bool {
        EcosystemVersion.compare(version, minimumVersion, scheme: .semver) != .orderedAscending
    }

    /// Why a Bun older than `minimumVersion` isn't used, and how to update it.
    static func unsupportedReason(_ version: String) -> String {
        "Bun \(version) is too old for BrewxPort. Update Bun to \(minimumVersion) or later with brew upgrade bun or "
            + "bun upgrade."
    }

    /// Before a query: throws `unsupportedReason` for a Bun older than `minimumVersion`, so nothing is listed, checked
    /// or looked up with it, whoever asks. Without a `detect()` first, Bun's version is asked now (and kept); one that
    /// can't be read is refused too.
    private func requireSupported() async throws {
        if state.version == nil {
            let result = try await tool.run(["--version"])
            guard result.exitCode == 0, let version = Self.version(result.stdout) else {
                throw EngineError(engine: .bun, message: "BrewxPort couldn't read Bun's version, so it doesn't use it.")
            }
            state.read(version: version)
        }
        try requireKnownSupported()
    }

    /// Before a command: throws `unsupportedReason` for a Bun older than `minimumVersion`, and refuses one whose
    /// version no `detect()` or query has read yet (a command can't wait to ask).
    private func requireKnownSupported() throws {
        guard let version = state.version else {
            throw EngineError(engine: .bun,
                              message: "BrewxPort hasn't checked Bun's version yet, so it doesn't run it.")
        }
        guard Self.isSupported(version) else {
            throw EngineError(engine: .bun, message: Self.unsupportedReason(version))
        }
    }

    // MARK: the global packages

    /// One top-level global package as `pm ls -g` prints it.
    struct Global: Equatable, Sendable {
        let name: String
        /// Its registry version; nil when it's installed from git, a folder or a tarball (that source isn't kept).
        let version: String?
    }

    /// The tree lines' prefixes in `pm ls -g`: `├── ` and `└── `.
    private static let treePrefixes = ["\u{251C}\u{2500}\u{2500} ", "\u{2514}\u{2500}\u{2500} "]

    /// The global packages in `pm ls -g`'s output, sorted by name: a header line (`<global folder> node_modules (N
    /// installed)`), then `├── name@resolution` for each top-level package. Anything else means the output isn't one
    /// BrewxPort knows, which is a failure rather than a short list; the message never repeats the line.
    static func globals(_ output: String) throws -> [Global] {
        let lines = output.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard let header = lines.first, globalFolder(header) != nil else { throw unreadableList }
        return try lines.dropFirst().map { line in
            guard let prefix = treePrefixes.first(where: { line.hasPrefix($0) }),
                  let global = parsed(line.dropFirst(prefix.count)) else { throw unreadableList }
            return global
        }.sorted { $0.name < $1.name }
    }

    /// The global folder in `pm ls -g`'s header, `/Users/x/.bun/install/global node_modules (2 installed)`: the
    /// absolute path before the last ` node_modules (`. Nil for any other line.
    static func globalFolder(_ header: Substring) -> String? {
        guard header.hasSuffix(" installed)"), let marker = header.range(of: " node_modules (", options: .backwards)
        else { return nil }
        let path = String(header[..<marker.lowerBound])
        return path.hasPrefix("/") ? path : nil
    }

    /// `name@resolution`, cut at the first `@` after a scope's: a resolution can be a path, a `github:` reference or a
    /// git URL with `@` in it. Only a semver resolution is kept as the version.
    private static func parsed(_ entry: Substring) -> Global? {
        guard let at = entry.dropFirst().firstIndex(of: "@") else { return nil }
        let name = String(entry[..<at])
        guard PackageNameRules.isValid(name, for: .bun) else { return nil }
        let resolution = String(entry[entry.index(after: at)...])
        return Global(name: name, version: EcosystemVersion.isValid(resolution, scheme: .semver) ? resolution : nil)
    }

    private static var unreadableList: EngineError {
        EngineError(engine: .bun, message: "Couldn't read Bun's list of global packages: it has a line BrewxPort "
                    + "doesn't know.")
    }

    // MARK: installed

    /// `pm ls -g`: every top-level global package, each asked for.
    public func listInstalled() async throws -> [Package] {
        try await listGlobals().map { global in
            Package(id: ref(global.name), displayName: global.name, installedVersion: global.version,
                    installedOnRequest: true)
        }
    }

    /// `pm ls -g`'s globals, remembered for `command(for:)` (R13).
    private func listGlobals() async throws -> [Global] {
        try await requireSupported()
        let result = try await tool.run(Self.listArguments)
        guard result.exitCode == 0 else { throw tool.failure("bun pm ls failed", result) }
        let globals = try Self.globals(result.stdout)
        state.listed(globals)
        return globals
    }

    // MARK: outdated

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// `outdated -g`: Bun's own check, which knows the registry Bun is set up for, after a listing that says which
    /// globals are from the npm registry (only those are offered, R13).
    public func checkOutdated() async throws -> OutdatedReport {
        let globals = try await listGlobals()
        let result = try await tool.run(Self.outdatedArguments)
        if result.exitCode == 0 {
            return OutdatedReport(packages: Self.updates(Self.registryRows(try Self.outdatedRows(result.stdout),
                                                                           of: globals)))
        }
        if result.exitCode == 1 {
            // Bun exits 1 when some lookups failed, after printing the rows it has: those count, and the packages it
            // couldn't check are left out, named in `unchecked` (R6). Before the first `add -g` there's no global
            // package.json, so nothing is outdated.
            if let rows = try? Self.outdatedRows(result.stdout), !rows.isEmpty {
                return OutdatedReport(packages: Self.updates(Self.registryRows(rows, of: globals)),
                                      unchecked: Self.unchecked(result.stderr))
            }
            if result.stderr.contains("missing package.json") { return OutdatedReport(packages: []) }
        }
        // Bun stopped before any row (every lookup failed, say), and said why on stderr.
        throw tool.failure("bun outdated failed", result)
    }

    /// The line Bun prints for a package it couldn't look up: `error: ConnectionRefused downloading package manifest
    /// semver` (`outdated-g-network-refused-stderr.txt`).
    private static let manifestFailure = " downloading package manifest "

    /// The packages a partial `outdated -g` names on stderr (`manifestFailure`), each with its line. When it names
    /// none, some unnamed package couldn't be checked.
    static func unchecked(_ stderr: String) -> UncheckedPackages {
        var reasons: [String: String] = [:]
        for line in stderr.split(whereSeparator: \.isNewline) {
            guard let marker = line.range(of: manifestFailure) else { continue }
            let name = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            guard PackageNameRules.isValid(name, for: .bun) else { continue }
            let text = line.trimmingCharacters(in: .whitespaces)
            reasons[name] = String(CredentialScrubber.scrub(text).prefix(300))
        }
        return UncheckedPackages(reasons: reasons, unnamed: reasons.isEmpty)
    }

    /// R13: the rows for globals `globals` shows as installed from the npm registry. One from git, a folder or a
    /// tarball (no registry version) is never offered: upgrading it by name would swap it for the registry's package
    /// of that name, maybe another project. Nor is a row for a package the listing doesn't have.
    static func registryRows(_ rows: [Package], of globals: [Global]) -> [Package] {
        let fromRegistry = Set(globals.filter { $0.version != nil }.map(\.name))
        return rows.filter { fromRegistry.contains($0.id.name) }
    }

    /// The rows of `outdated -g`'s table (`| Package | Current | Update | Latest |`), found by their headings. Only
    /// lines starting with `|` are read: dash rows are skipped, a package name loses Bun's ` (dev)`-style note and a
    /// version its ` *` (a version `minimumReleaseAge` held back to, the one Bun would install). A name Bun couldn't
    /// install by name (an alias, `name@npm:other`) is left out. No table means nothing is outdated; a table without
    /// those headings isn't one BrewxPort knows.
    static func outdatedRows(_ output: String) throws -> [Package] {
        var columns: (name: Int, current: Int, latest: Int)?
        var rows: [Package] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" } }) { continue }
            guard let found = columns else {
                guard let name = cells.firstIndex(of: "Package"), let current = cells.firstIndex(of: "Current"),
                      let latest = cells.firstIndex(of: "Latest") else {
                    throw EngineError(engine: .bun, message: "Couldn't read bun outdated's table: its columns "
                                      + "aren't the ones BrewxPort knows.")
                }
                columns = (name, current, latest)
                continue
            }
            guard cells.count > max(found.name, found.current, found.latest),
                  let name = cells[found.name].split(separator: " ").first.map(String.init),
                  PackageNameRules.isValid(name, for: .bun) else { continue }
            rows.append(Package(id: PackageRef(engine: .bun, kind: .tool, name: name), displayName: name,
                                installedVersion: nonBlank(cells[found.current]),
                                latestVersion: nonBlank(withoutMark(cells[found.latest]))))
        }
        return rows.sorted { $0.id.name < $1.id.name }
    }

    /// A version cell without the ` *` Bun adds when `minimumReleaseAge` held it back.
    private static func withoutMark(_ cell: String) -> String {
        guard cell.hasSuffix("*") else { return cell }
        return String(cell.dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The rows that are real updates. Only Latest counts (an upgrade is `update -g --latest`), and only when it's
    /// newer than what's installed by semver: never a downgrade, a pre-release for a stable install, or anything for
    /// a global that isn't from the registry.
    static func updates(_ rows: [Package]) -> [Package] {
        rows.compactMap { row in
            guard let installed = row.installedVersion, let latest = row.latestVersion,
                  let newer = EcosystemVersion.newerVersion(than: installed, among: [latest], scheme: .semver)
            else { return nil }
            var update = row
            update.latestVersion = newer
            return update
        }.sorted { $0.id.name < $1.id.name }
    }

    // MARK: search

    private struct SearchAnswer: Decodable {
        struct Object: Decodable {
            struct Hit: Decodable {
                let name: String?
                let version: String?
                let description: String?
            }
            let package: Hit?
        }
        let objects: [Object]
    }

    /// The characters a search query keeps as they are in the URL: RFC 3986's unreserved ones, ASCII only.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The npm registry's search for `query`, percent-encoded so it can't add a parameter or end the address.
    static func searchURL(_ query: String) -> URL? {
        guard let text = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://registry.npmjs.org/-/v1/search?text=\(text)&size=\(searchSize)")
    }

    /// The npm registry's search (its 50 best matches), which Bun has no command for. The query is the only text
    /// sent. A name Bun couldn't install by name is left out.
    public func search(_ query: String) async throws -> [Package] {
        try await requireSupported()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError(engine: .bun, message: "Search query is empty") }
        guard let url = Self.searchURL(text) else {
            throw EngineError(engine: .bun, message: "BrewxPort couldn't make a search for that text.")
        }
        let data = try await Self.fetch(url, from: registry)
        let answer: SearchAnswer
        do {
            answer = try JSONDecoder().decode(SearchAnswer.self, from: data)
        } catch {
            throw EngineError(engine: .bun, message: "Couldn't read the npm registry's search answer")
        }
        return answer.objects.compactMap(\.package).compactMap { hit in
            guard let name = hit.name, PackageNameRules.isValid(name, for: .bun) else { return nil }
            return Package(id: ref(name), displayName: name, latestVersion: nonBlank(hit.version),
                           summary: nonBlank(hit.description))
        }
    }

    // MARK: info

    /// The fields of `bun info --json` that details show. Fields npm packages give in more than one shape (`bin`,
    /// `author`, `repository`) aren't read, so one of them can't stop the answer being read.
    private struct Info: Decodable {
        let name: String?
        let version: String?
        let description: String?
        let homepage: String?
    }

    /// `bun info <name> --json`: the latest version's details from the registry Bun is set up for. Below
    /// `minimumVersion`, the reason it's unsupported (Bun 1.2's `info` is a reserved command).
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .bun, ref.kind == .tool else {
            throw EngineError(engine: .bun, message: "Package belongs to a different engine")
        }
        try PackageNameRules.validate(ref.name, for: .bun)
        try await requireSupported()
        let result = try await tool.run(["info", ref.name, "--json"])
        // An unknown package or an unreachable registry: exit 1, nothing on stdout, Bun's words on stderr.
        guard result.exitCode == 0 else { throw tool.failure("bun info failed", result) }
        let info = try tool.decode(Info.self, from: result.stdout)
        guard let name = nonBlank(info.name), let version = nonBlank(info.version) else {
            throw EngineError(engine: .bun, message: "Bun had no information for \(ref.name)")
        }
        return PackageDetails(ref: ref, summary: nonBlank(info.description), homepage: webURL(info.homepage),
                              latestVersion: version, reportedName: name)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// `add -g`, `update -g --latest` (plain `update -g` stays inside the range `add -g` saved) and `remove -g`, for
    /// registry names only. Each takes several names, so a batch is one command; never `--trust`, which would run
    /// dependency install scripts. An upgrade is only for globals the last listing showed from the npm registry
    /// (`upgradable`, R13).
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        // Without names, `update -g --latest` would update every global package.
        guard !refs.isEmpty else { throw EngineError(engine: .bun, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .bun && $0.kind == .tool }) else {
            throw EngineError(engine: .bun, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .bun, message: "Bun installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .bun, message: "Bun has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .bun, message: "Bun commands take no extra arguments")
        }
        try requireKnownSupported()
        try access.requireWritable(for: op, engine: .bun)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .bun) }
        let names = refs.map(\.name)
        switch op {
        case .install: return try tool.command(["add", "-g"] + names)
        case .upgrade:
            try upgradable(names)
            return try tool.command(["update", "-g", "--latest"] + names)
        case .remove: return try tool.command(["remove", "-g"] + names)
        case .repair:
            throw EngineError(engine: .bun, message: "Bun repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .bun, message: "Bun can't mark packages")
        }
    }

    /// R13: refuses, with a one-line reason that never shows the source, an upgrade of a global the last listing
    /// (by `detect()`, the installed list or an outdated check) showed isn't from the npm registry, and of one it
    /// didn't show at all.
    private func upgradable(_ names: [String]) throws {
        let listed = state.globals
        for name in names {
            guard let global = listed?[name] else {
                throw EngineError(engine: .bun, message: "BrewxPort can't find \(name) among Bun's global packages, "
                                  + "so it doesn't update it.")
            }
            guard global.version != nil else {
                throw EngineError(engine: .bun, message: "\(name) wasn't installed from the npm registry, so "
                                  + "BrewxPort doesn't update it.")
            }
        }
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .bun, kind: .tool, name: name) }

    /// One GET to the npm registry. Its refusals and being offline are `EngineError`s; anything else (a cancelled task,
    /// demo mode's uncaptured answer) is thrown as it is.
    private static func fetch(_ url: URL, from registry: any RegistryFetching) async throws -> Data {
        do {
            return try await registry.get(url)
        } catch let error as RegistryFetchError {
            throw EngineError(engine: .bun, message: "The npm registry didn't answer: \(error)")
        } catch let error as URLError where error.code != .cancelled {
            throw EngineError(engine: .bun, message: "Couldn't reach the npm registry: \(error.localizedDescription)")
        }
    }

    /// What the last `detect()` found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedVersion: String?
        private var global: URL?
        private var bin: URL?
        private var listing: [String: Global]?

        var version: String? { lock.withLock { detectedVersion } }
        var globalDirectory: URL? { lock.withLock { global } }
        var binDirectory: URL? { lock.withLock { bin } }
        /// The last listing's globals by name; nil before one, or when the last one couldn't be read.
        var globals: [String: Global]? { lock.withLock { listing } }

        func listed(_ found: [Global]?) {
            let map = found.map { Dictionary($0.map { ($0.name, $0) }) { first, _ in first } }
            lock.withLock { listing = map }
        }

        func detected(version: String?, globalDirectory: URL?, binDirectory: URL?) {
            lock.withLock {
                detectedVersion = version
                global = globalDirectory
                bin = binDirectory
            }
        }

        /// A version a query read before any `detect()`.
        func read(version: String) { lock.withLock { detectedVersion = version } }
    }
}

// MARK: Task 10: commands

extension BunEngine: ExecutableNaming {
    /// The commands a global's own package.json declares, in the global folder the last detect found.
    public func executables(of name: String) -> [String]? {
        guard PackageNameRules.isValid(name, for: .bun), let global = state.globalDirectory else { return nil }
        let folder = global.appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        return NodePackageExecutables.read(packageFolder: folder, name: name)
    }
}
