import Foundation

/// Mint's Swift command-line tools: packages on GitHub that `mint install owner/repo@tag` clones, builds from source
/// and links into Mint's bin folder. Always as the user, never as root (Plan 9). Found from the login shell's PATH
/// first, then the fixed folders (`fixedFolders`).
///
/// - Folders: MINT_PATH (else `~/.mint`) holds the packages and Mint's metadata, MINT_LINK_PATH (else `~/.mint/bin`)
///   the linked executables. Both come from the login shell.
/// - Installed: every package `mint list` shows, read strictly (Mint can print an error and still exit 0). It names a
///   package only by its repository's last part, so which repository that is comes from Mint's own `metadata.json`
///   in MINT_PATH, read without running anything (`readMetadata`). A package is a tool at the version whose
///   executables are linked (`*`); unlinked versions are what `mint run` and older installs left behind. One that
///   isn't exactly one plain `https://github.com/owner/repo.git` with a linked version is listed by what's known (its
///   owner/repo or Mint's own name, its versions) with a reason in `unmapped` (R24): never checked, updated or
///   installed, only removed. Its URL is never kept or shown.
/// - Newer versions: each tool's tags, from GitHub through git (`lookUp`, R21), hardened so the user's git settings
///   can't send the lookup elsewhere and it never asks for a password. Only version tags count (semver, a leading `v`
///   allowed), a pre-release only for a pre-release. A failed lookup is that tool's alone (`couldntCheck`, R6); when
///   none answers, the check fails.
/// - Discover has no registry to search: an `owner/repo` query whose tags can be looked up is one result, at its
///   newest version.
/// - Install and upgrade are `mint install --overwrite n owner/repo@tag`, with a tag a lookup found (R20), never one
///   from the user: without a tag, Mint would read a Mintfile in the working folder. Uninstall names the repository's
///   URL and removes every version. Mint exits 0 when it skipped a link or found nothing to remove, so each change is
///   confirmed by `mint list` afterwards (`ConfirmationCheck`, R17). Mint takes one package per command.
public struct MintEngine: Engine, InstallLocationReporting {
    public let id: EngineID = .mint
    /// Mint prints text, and every install is a source build without variants.
    public let capabilities: EngineCapabilities = []

    /// Reads Mint's `metadata.json` by path: nil when there's no such file; throws when it's there but can't be read.
    /// Demo mode and tests pass their own, so neither reads this Mac's `~/.mint`.
    public typealias MetadataReader = @Sendable (_ path: String) throws -> Data?

    /// The app's reader: the file on disk.
    public static let readFile: MetadataReader = { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static let listArguments = ["list"]
    /// git's settings for a tag lookup (R21): HTTPS only, no credential helper and no password program, whatever the
    /// user's git config says.
    public static let gitOptions = ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c",
                                    "credential.helper=", "-c", "core.askPass="]
    /// The variables a tag lookup adds to the base environment (R21): no prompt, no system or global git config (so no
    /// `url.<x>.insteadOf` can redirect it), and no password program. HOME and XDG_CONFIG_HOME point at an empty
    /// folder as well, for a git older than 2.32, which ignores GIT_CONFIG_GLOBAL.
    static let gitVariables = ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
                               "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty"]
    /// Where a tag lookup runs (R25): outside any repository, whose own config git would otherwise read.
    static let gitFolder = "/"
    /// Where git is looked for after the login shell's PATH (R21), before Apple's `/usr/bin/git`.
    static let fixedGitFolders = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// Apple's git: a shim that opens the Command Line Tools' install dialog when they aren't there.
    static let systemGitFolder = "/usr/bin"
    static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")
    /// Tag lookups at a time, for an outdated check.
    static let concurrentLookups = 4
    static let gitHub = "https://github.com/"

    private let tool: LanguageTool
    private let runner: CommandRunning
    private let base: [String: String]
    private let home: String
    private let readMetadata: MetadataReader
    private let findGit: @Sendable () async -> URL?
    private let state = State()
    private let access: InstallAccessState

    public var executableURL: URL? { tool.executable }

    /// Why this account can't change Mint's packages: the last detect found MINT_PATH or MINT_LINK_PATH not writable.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// MINT_PATH as the last `detect()` found it: where Mint keeps its packages and metadata.
    public var installLocation: URL? { state.folders?.install }

    /// MINT_LINK_PATH as the last `detect()` found it: where Mint links executables (Task 10's PATH note).
    public var binLocation: URL? { state.folders?.bin }

    /// The tools the last outdated check couldn't look up (R6): name → a one-line reason. They aren't in Updates.
    public var couldntCheck: [String: String] { state.unchecked }

    /// The packages the last listing couldn't map to exactly one GitHub `owner/repo` with a linked version (R24):
    /// name → a one-line reason. They're in Installed, but never checked, updated or installed; they can be removed.
    public var unmapped: [String: String] { state.unmappedReasons }

    /// The app's mint: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). git for the
    /// tag lookups is found the same way (`locateGit`). `base` is the environment every command starts from;
    /// `readMetadata` reads Mint's metadata.
    public init(runner: CommandRunning, loginShell: @escaping LoginShellContextProvider, arch: Arch = .current,
                base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                readMetadata: @escaping MetadataReader = MintEngine.readFile,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .mint, name: "mint", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.runner = runner
        self.base = base
        self.home = home
        self.readMetadata = readMetadata
        access = InstallAccessState(isWritable: isWritable)
        findGit = {
            let context = await loginShell()
            return await Self.locateGit(loginPath: context.path) {
                await Self.commandLineToolsPresent(runner: runner, base: base)
            }
        }
    }

    /// mint and git at fixed paths (demo mode and tests), with these login-shell variables; nil means not installed.
    /// Its folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, executable: URL?, git: URL?, captured: [String: String] = [:],
                base: [String: String] = ProcessRunner.baseEnvironment,
                readMetadata: @escaping MetadataReader = MintEngine.readFile,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true }) {
        tool = LanguageTool(engine: .mint, name: "mint", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.runner = runner
        self.base = base
        home = LanguageTool.home(base)
        self.readMetadata = readMetadata
        access = InstallAccessState(isWritable: isWritable)
        findGit = { git }
    }

    // MARK: finding mint and git

    /// Where mint is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first),
    /// MacPorts', then Mint's own bin folder (MINT_LINK_PATH, then `~/.mint/bin`), where `mint install yonaskolb/mint`
    /// puts it.
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        let prefixes: [String] = arch == .arm64 ? ["/opt/homebrew", "/usr/local"] : ["/usr/local", "/opt/homebrew"]
        var folders: [String] = prefixes.map { $0 + "/bin" }
        folders.append("/opt/local/bin")
        if let link = captured["MINT_LINK_PATH"] { folders.append(link) }
        folders.append(home + "/.mint/bin")
        return folders
    }

    /// git as R21 finds it: the first on the login shell's PATH, then in `fixed`, then Apple's in `system`. Apple's
    /// is a shim that opens an install dialog without the Command Line Tools, so wherever it comes in the order, and
    /// whatever link leads to it (`~/bin/git -> /usr/bin/git`: the git file's own resolved folder decides), it's taken
    /// only when `commandLineTools` says they're there; otherwise the next git that isn't it is.
    static func locateGit(loginPath: [String], fixed: [String] = fixedGitFolders, system: String = systemGitFolder,
                          commandLineTools: () async -> Bool) async -> URL? {
        let locator = ToolLocator()
        let shim = ToolLocator.realPath(system) ?? system
        func isShim(_ git: String) -> Bool {
            ToolLocator.realPath(git).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } == shim
        }
        let folders = loginPath + fixed + [system]
        guard let found = locator.locate("git", loginPath: folders, fixed: []) else { return nil }
        guard isShim(found.path) else { return found }
        if await commandLineTools() { return found }
        return locator.locate("git", loginPath: folders.filter { !isShim($0 + "/git") }, fixed: [])
    }

    /// Whether the Command Line Tools (or Xcode) are there: `xcode-select -p` exits 0, without a dialog either way.
    static func commandLineToolsPresent(runner: CommandRunning, base: [String: String]) async -> Bool {
        let options = RunOptions(environment: base, timeout: BrewxPortTimeouts.registryQuery)
        guard let result = try? await runner.run(xcodeSelect, ["-p"], options: options) else { return false }
        return result.exitCode == 0
    }

    // MARK: detect

    /// Mint's version, then its folders for `installLocation` and `binLocation`.
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { Self.version($0) }
        if case .present = status {
            state.detected(install: URL(fileURLWithPath: mintPath, isDirectory: true),
                           bin: URL(fileURLWithPath: linkPath, isDirectory: true))
        } else {
            state.forgetFolders()
        }
        access.checked(.mint, folders: state.folders.map { [$0.install, $0.bin] } ?? [], home: home)
        return status
    }

    /// `mint --version`'s `Version: 0.18.0`. Only that shape: Homebrew's mintoolkit also installs a `mint`.
    static func version(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("Version: ") else { return nil }
        let version = line.dropFirst("Version: ".count).trimmingCharacters(in: .whitespaces)
        return EcosystemVersion.isValid(version, scheme: .semver) ? version : nil
    }

    private var mintPath: String { tool.variable("MINT_PATH") ?? home + "/.mint" }
    private var linkPath: String { tool.variable("MINT_LINK_PATH") ?? home + "/.mint/bin" }
    /// Mint's record of which repository each package came from.
    private var metadataPath: String { mintPath + "/metadata.json" }

    // MARK: mint list

    /// One package as `mint list` shows it: the repository's last part, the repository itself only when another
    /// package has the same name, and each version folder.
    struct Listed: Equatable, Sendable {
        let name: String
        let repository: String?
        var versions: [ListedVersion]
    }

    /// One version folder of a package: its name (the tag as written), its executables when Mint names them (it
    /// doesn't when there's one with the package's name), whether any of them is linked, and whether only some are
    /// (`(a *, b)`: Mint skipped a link, for one it wasn't allowed to replace).
    struct ListedVersion: Equatable, Sendable {
        let version: String
        let executables: [String]?
        let linked: Bool
        var partlyLinked = false
    }

    /// `mint list`'s packages, its `🌱 ` taken off: the `Installed mint packages:` header then `  Name` lines (with
    /// ` (gitRepo)` when two share a name), each followed by `    - version` lines with optional `(executables)` and
    /// `*` marks; or `No mint packages installed`. Blank lines are skipped; anything else is a failure rather than a
    /// short list, since Mint can exit 0 when it failed. The message never repeats the line.
    static func listed(_ output: String) throws -> [Listed] {
        var header: String?
        var packages: [Listed] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.hasPrefix("🌱 ") ? raw.dropFirst(2) : raw
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let found = header else {
                guard line == "Installed mint packages:" || line == "No mint packages installed" else {
                    throw unreadableList
                }
                header = String(line)
                continue
            }
            guard found == "Installed mint packages:" else { throw unreadableList }
            if line.hasPrefix("    - ") {
                guard !packages.isEmpty, let version = listedVersion(line.dropFirst(6)) else { throw unreadableList }
                packages[packages.count - 1].versions.append(version)
            } else if line.hasPrefix("  "), !line.hasPrefix("   "), let package = listedPackage(line.dropFirst(2)) {
                packages.append(package)
            } else {
                throw unreadableList
            }
        }
        guard header != nil else { throw unreadableList }
        return packages
    }

    /// `Name` or `Name (gitRepo)`.
    private static func listedPackage(_ text: Substring) -> Listed? {
        var name = text
        var repository: String?
        if text.hasSuffix(")"), let open = text.range(of: " (") {
            name = text[..<open.lowerBound]
            let inside = text[open.upperBound..<text.index(before: text.endIndex)]
            guard !inside.isEmpty, !inside.contains(" ") else { return nil }
            repository = String(inside)
        }
        guard !name.isEmpty, !name.contains(" "), !name.contains("(") else { return nil }
        return Listed(name: String(name), repository: repository, versions: [])
    }

    /// `version`, then optionally `(a, b)` (each maybe with ` *`), then optionally `*`.
    private static func listedVersion(_ text: Substring) -> ListedVersion? {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard let version = parts.first, !version.isEmpty else { return nil }
        var rest = parts.count > 1 ? parts[1] : ""
        var executables: [String]?
        var starred = 0
        if rest.hasPrefix("(") {
            guard let close = rest.firstIndex(of: ")") else { return nil }
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            var names: [String] = []
            for entry in inside.isEmpty ? [] : inside.components(separatedBy: ", ") {
                var name = entry
                if name.hasSuffix(" *") {
                    name.removeLast(2)
                    starred += 1
                }
                guard !name.isEmpty, !name.contains(" "), !name.contains(",") else { return nil }
                names.append(name)
            }
            executables = names
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        let all: Bool
        switch rest {
        case "": all = false
        case "*": all = true
        default: return nil
        }
        // A star after the brackets marks them all; stars inside mark some (all of them, if every one has one).
        let every = all || (starred > 0 && starred == executables?.count)
        return ListedVersion(version: String(version), executables: executables, linked: all || starred > 0,
                             partlyLinked: !every && starred > 0)
    }

    private static var unreadableList: EngineError {
        EngineError(engine: .mint, message: "Couldn't read Mint's list of packages: it has a line BrewxPort doesn't "
                    + "know.")
    }

    // MARK: installed tools

    /// One package `mint list` shows: its `owner/repo` (for one BrewxPort can't map, Mint's own name when the
    /// repository isn't known), the linked version (else the highest one Mint has) and that version's executables (nil
    /// when Mint doesn't name them). `unmapped` says why BrewxPort doesn't manage it (R24); nil for a tool it does.
    struct Tool: Equatable, Sendable {
        let name: String
        let version: String?
        let executables: [String]?
        var unmapped: String? = nil
    }

    /// R24's reasons, one line each.
    static func notGitHub(_ name: String) -> String {
        "Mint installed \(name) from somewhere other than a plain GitHub address, so BrewxPort doesn't update it."
    }

    static func unknownRepository(_ name: String) -> String {
        "BrewxPort can't tell which repository Mint's \(name) came from, so it doesn't update it."
    }

    static func notLinked(_ name: String) -> String {
        "No version of \(name) is linked into Mint's bin folder (Mint keeps it only as a cache), so BrewxPort doesn't "
            + "update it."
    }

    static func sameName(_ name: String) -> String {
        "More than one Mint package is called \(name), so BrewxPort doesn't update them."
    }

    /// Mint's `metadata.json`: each package's git URL → its folder.
    private struct Metadata: Decodable {
        let packages: [String: String]
    }

    /// The git URLs in Mint's metadata.
    static func repositories(metadata data: Data) throws -> [String] {
        do {
            return try JSONDecoder().decode(Metadata.self, from: data).packages.keys.sorted()
        } catch {
            throw unreadableMetadata
        }
    }

    private static var unreadableMetadata: EngineError {
        EngineError(engine: .mint, message: "Couldn't read Mint's metadata.json, which says which repository each "
                    + "installed package came from.")
    }

    /// `owner/repo` for a plain `https://github.com/owner/repo.git` that Mint could have been given as `owner/repo`;
    /// nil for any other URL (another host, ssh, credentials, a path).
    public static func packageName(repository: String) -> String? {
        guard repository.hasPrefix(gitHub), repository.hasSuffix(".git") else { return nil }
        let name = String(repository.dropFirst(gitHub.count).dropLast(".git".count))
        return PackageNameRules.isValid(name, for: .mint) ? name : nil
    }

    /// The URL Mint clones for `owner/repo`.
    public static func repositoryURL(_ name: String) -> String { gitHub + name + ".git" }

    /// The name `mint list` shows for a repository: its URL's last part with every ".git" taken out, as Mint does.
    static func listName(repository: String) -> String {
        (repository.components(separatedBy: "/").last ?? repository).replacingOccurrences(of: ".git", with: "")
    }

    /// Every package in `listed`, sorted by name. Its repository is the URL Mint printed beside it, else the one
    /// metadata URL of its name. It's a tool when that's a plain GitHub URL and a version is linked: named
    /// `owner/repo`, at the linked version (the highest, if several are). Otherwise it's listed with a reason (R24):
    /// Mint's own name when the repository isn't one BrewxPort can name, the linked version or else the highest. Two
    /// packages that would share a name make one row, which says so.
    static func tools(_ listed: [Listed], repositories: [String]) -> [Tool] {
        let byName = Dictionary(grouping: repositories, by: listName(repository:))
        func highest(_ versions: [ListedVersion]) -> ListedVersion? {
            versions.max { EcosystemVersion.compare($0.version, $1.version, scheme: .semver) == .orderedAscending }
        }
        var rows: [String: Tool] = [:]
        for entry in listed {
            var name = entry.name
            var reason: String?
            if let repository = entry.repository ?? byName[entry.name].flatMap({ $0.count == 1 ? $0[0] : nil }) {
                if let mapped = packageName(repository: repository) {
                    name = mapped
                } else {
                    reason = notGitHub(entry.name)
                }
            } else {
                reason = unknownRepository(entry.name)
            }
            let linked = entry.versions.filter(\.linked)
            if reason == nil, linked.isEmpty { reason = notLinked(name) }
            let shown = highest(linked) ?? highest(entry.versions)
            let row = Tool(name: name, version: shown?.version, executables: shown?.executables, unmapped: reason)
            if let first = rows[name] {
                rows[name] = Tool(name: name, version: first.version, executables: first.executables,
                                  unmapped: sameName(name))
            } else {
                rows[name] = row
            }
        }
        return rows.values.sorted { $0.name < $1.name }
    }

    /// Every package Mint lists, each asked for: the ones BrewxPort can't manage too (R24, `unmapped`).
    public func listInstalled() async throws -> [Package] {
        try await listTools().map { tool in
            Package(id: ref(tool.name), displayName: tool.name, installedVersion: tool.version,
                    installedOnRequest: true)
        }
    }

    /// `mint list`'s tools, named from Mint's metadata. Remembered for `info`.
    private func listTools() async throws -> [Tool] {
        let result = try await tool.run(Self.listArguments)
        guard result.exitCode == 0 else { throw tool.failure("mint list failed", result) }
        let listed = try Self.listed(result.stdout)
        let tools = listed.isEmpty ? [] : Self.tools(listed, repositories: try repositories())
        state.listed(tools)
        return tools
    }

    /// The git URLs in MINT_PATH's metadata. Mint can't list a package without it, so a missing or unreadable file
    /// is a failure.
    private func repositories() throws -> [String] {
        let data: Data?
        do {
            data = try readMetadata(metadataPath)
        } catch {
            throw Self.unreadableMetadata
        }
        guard let data else { throw Self.unreadableMetadata }
        return try Self.repositories(metadata: data)
    }

    // MARK: tags

    /// The tags in `git ls-remote --tags --refs`'s `<sha>\trefs/tags/<tag>` lines, in git's order. Only tags Mint can
    /// pass on safely (`isSafeTag`) are kept; other lines are skipped.
    static func tags(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { return nil }
            let tag = String(fields[1].dropFirst("refs/tags/".count))
            return isSafeTag(tag) ? tag : nil
        }
    }

    /// R20: a letter or digit, then letters, digits and `._+-`. Mint puts the tag into a bash command line (`git
    /// clone -b <tag>`), and git allows `$`, `;` and backticks in tag names.
    static func isSafeTag(_ tag: String) -> Bool {
        guard let first = tag.unicodeScalars.first, isLetterOrDigit(first) else { return false }
        return tag.unicodeScalars.allSatisfy { isLetterOrDigit($0) || "._+-".unicodeScalars.contains($0) }
    }

    /// An ASCII letter or digit.
    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }

    /// The highest version tag, as written (`v1.2.0`); pre-releases only when asked for. Nil when there's none.
    static func newest(_ tags: [String], includingPrereleases: Bool) -> String? {
        tags.filter {
            EcosystemVersion.isValid($0, scheme: .semver)
                && (includingPrereleases || !EcosystemVersion.isPrerelease($0, scheme: .semver))
        }.max { EcosystemVersion.compare($0, $1, scheme: .semver) == .orderedAscending }
    }

    /// `owner/repo`'s tags from GitHub (R21): git with `gitOptions`, the base environment and `gitVariables` only,
    /// from `/`, for at most `BrewxPortTimeouts.registryQuery`. Every failure is an `EngineError` saying why; a
    /// cancelled task is thrown as it is.
    private func lookUp(_ name: String, git: URL?) async throws -> [String] {
        try PackageNameRules.validate(name, for: .mint)
        guard let git else {
            throw EngineError(engine: .mint, message: "BrewxPort looks up Mint packages' versions with git, and git "
                              + "isn't installed.")
        }
        let options = RunOptions(environment: base.merging(Self.gitVariables) { $1 },
                                 timeout: BrewxPortTimeouts.registryQuery, workingDirectory: Self.gitFolder)
        let result: CommandResult
        do {
            result = try await runner.run(git, Self.lsRemoteArguments(name), options: options)
        } catch CommandRunnerError.timedOut(let after) {
            throw EngineError(engine: .mint, message: "GitHub \(BrewxPortTimeouts.didntAnswer(within: after)) about "
                              + "\(name).")
        } catch let error as CommandRunnerError {
            throw EngineError(engine: .mint, message: "Couldn't run git to look up \(name): \(error)")
        }
        guard result.exitCode == 0 else { throw Self.lookupFailure(name, result) }
        return Self.tags(result.stdout)
    }

    /// git's arguments for `owner/repo`'s tags: `gitOptions`, then `ls-remote --tags --refs <url>` as captured.
    public static func lsRemoteArguments(_ name: String) -> [String] {
        gitOptions + ["ls-remote", "--tags", "--refs", repositoryURL(name)]
    }

    /// What a failed lookup says. git asks for a user name when GitHub has no public repository of that name (it
    /// doesn't say "not found"); anything else is git's own words, credentials taken out.
    static func lookupFailure(_ name: String, _ result: CommandResult) -> EngineError {
        if result.stderr.contains("could not read Username") {
            return EngineError(engine: .mint, message: "GitHub has no public repository named \(name).")
        }
        let excerpt = String(CredentialScrubber.scrub(result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return EngineError(engine: .mint, message: "git couldn't list the tags of \(name) (exit \(result.exitCode))"
                           + (excerpt.isEmpty ? "" : ": \(excerpt)"))
    }

    // MARK: outdated

    /// The tools BrewxPort manages (not `unmapped`, R24) whose installed version is a version: one installed from a
    /// branch or commit (`@main`) has nothing to compare.
    static func checkable(_ tools: [Tool]) -> [Tool] {
        tools.filter { tool in
            tool.unmapped == nil && tool.version.map { EcosystemVersion.isValid($0, scheme: .semver) } == true
        }
    }

    /// What an outdated check found: the updates, and the tools it couldn't look up.
    struct Check {
        var updates: [Package] = []
        var couldntCheck: [String: String] = [:]
    }

    /// Each tool's tags (by name) against its installed version: the highest newer version tag, a pre-release only for
    /// a pre-release, offered as the tag is written. Throws when no lookup answered.
    static func updates(_ tools: [Tool], tags: [String: Result<[String], any Error>]) throws -> Check {
        var updates: [Package] = []
        let unchecked = try OutdatedLookups.tally(
            tools, answers: tags, key: \.name, name: \.name,
            noAnswer: { failure in
                EngineError(engine: .mint, message: "BrewxPort couldn't check GitHub for newer versions: "
                            + (failure.map(OutdatedLookups.describe) ?? "nothing could be looked up."))
            }
        ) { tool, found in
            guard tool.unmapped == nil, let installed = tool.version,
                  let newer = EcosystemVersion.newerVersion(than: installed, among: found, scheme: .semver)
            else { return }
            updates.append(Package(id: PackageRef(engine: .mint, kind: .tool, name: tool.name), displayName: tool.name,
                                   installedVersion: tool.version, latestVersion: newer))
        }
        return Check(updates: updates.sorted { $0.id.name < $1.id.name }, couldntCheck: unchecked.reasons)
    }

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// Each tool with a version looked up on GitHub, a few at a time. A lookup that fails leaves that tool out (R6,
    /// named in `unchecked` and kept in `couldntCheck`); when none answers, the check fails. The newer tags found are
    /// what upgrades install. The last check's tags stay until this one ends, so an update picked from its rows still
    /// has its tag while a background check runs; a check that fails as a whole leaves none behind (a cancelled one
    /// changes nothing).
    public func checkOutdated() async throws -> OutdatedReport {
        state.clearCouldntCheck()
        do {
            let check = try await check()
            let newer = check.updates.compactMap { row in row.latestVersion.map { (row.id.name, $0) } }
            state.checked(updates: Dictionary(newer) { first, _ in first }, couldntCheck: check.couldntCheck)
            return OutdatedReport(packages: check.updates, unchecked: UncheckedPackages(reasons: check.couldntCheck))
        } catch let error as CancellationError {
            throw error
        } catch {
            state.checked(updates: [:], couldntCheck: [:])
            throw error
        }
    }

    /// The listing's versioned tools, each looked up.
    private func check() async throws -> Check {
        let tools = Self.checkable(try await listTools())
        guard !tools.isEmpty else { return Check() }
        let git = await findGit()
        let answers = try await concurrentMap(tools.map(\.name), limit: Self.concurrentLookups) { name in
            do {
                return Result<[String], any Error>.success(try await lookUp(name, git: git))
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        return try Self.updates(tools, tags: answers)
    }

    // MARK: search

    /// No registry search: a query that is exactly `owner/repo` is looked up on GitHub, and one whose newest stable
    /// version tag is found is the one result. Anything else, or a lookup that fails, finds nothing.
    public func search(_ query: String) async throws -> [Package] {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EngineError(engine: .mint, message: "Search query is empty") }
        guard PackageNameRules.isValid(name, for: .mint) else { return [] }
        let git = await findGit()
        guard let tags = try? await lookUp(name, git: git),
              let newest = Self.newest(tags, includingPrereleases: false) else { return [] }
        state.found(name, newest: newest)
        return [Package(id: ref(name), displayName: name, latestVersion: newest)]
    }

    // MARK: info

    /// The package's GitHub page, with the installed version and executables from the last listing and the newest
    /// version the last check or search found, else looked up now (a failed lookup leaves it out). For a package the
    /// last listing couldn't map (R24), only what that listing knew, and a GitHub page only for an `owner/repo`.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .mint, ref.kind == .tool else {
            throw EngineError(engine: .mint, message: "Package belongs to a different engine")
        }
        let installed = state.tool(ref.name)
        if let installed, installed.unmapped != nil {
            let page = PackageNameRules.isValid(ref.name, for: .mint) ? URL(string: Self.gitHub + ref.name) : nil
            return PackageDetails(ref: ref, homepage: page, installedVersion: installed.version,
                                  executables: installed.executables)
        }
        try PackageNameRules.validate(ref.name, for: .mint)
        var latest = state.update(ref.name) ?? state.newest(ref.name)
        if latest == nil {
            let git = await findGit()
            if let tags = try? await lookUp(ref.name, git: git) {
                let prerelease = installed?.version.map { EcosystemVersion.isPrerelease($0, scheme: .semver) } ?? false
                latest = Self.newest(tags, includingPrereleases: prerelease)
            }
        }
        return PackageDetails(ref: ref, homepage: URL(string: Self.gitHub + ref.name),
                              installedVersion: installed?.version, latestVersion: latest,
                              executables: installed?.executables)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// Mint installs, updates and removes one package per command.
    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? {
        operation == .install || operation == .upgrade || operation == .remove ? 1 : nil
    }

    /// One package per command (`maxTargetsPerCommand`). Install and upgrade run `mint install --overwrite n owner/repo@tag` (R20): an install
    /// with the newest tag Discover found, an upgrade with the newer tag the last check found, never a version from
    /// the user. `--overwrite n` keeps a file Mint didn't put in its bin folder. Uninstall names the repository's
    /// URL (Mint matches any package whose URL contains its argument). Each is confirmed by `mint list`. A package
    /// the last listing couldn't map (R24) is never installed or updated; it's removed by its URL when it's an
    /// `owner/repo`, else by Mint's own name (`removeByMintName`).
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard !refs.isEmpty else { throw EngineError(engine: .mint, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .mint && $0.kind == .tool }) else {
            throw EngineError(engine: .mint, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .mint, message: "Mint installs the newest version BrewxPort found on GitHub only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .mint, message: "Mint has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .mint, message: "Mint commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .mint)
        try requireTargetLimit(refs, for: op)
        let name = refs[0].name
        if let reason = state.tool(name)?.unmapped {
            guard op == .remove else { throw EngineError(engine: .mint, message: reason) }
            if !PackageNameRules.isValid(name, for: .mint) { return try removeByMintName(name) }
        }
        try PackageNameRules.validate(name, for: .mint)
        switch op {
        case .install:
            guard let tag = state.newest(name) ?? state.update(name) else {
                throw EngineError(engine: .mint, message: "BrewxPort hasn't looked up \(name.possessive) versions on "
                                  + "GitHub, so it doesn't know which to install. Find it in Discover first.")
            }
            return try install(name, tag: tag)
        case .upgrade:
            guard let tag = state.update(name) else {
                throw EngineError(engine: .mint, message: "BrewxPort hasn't found a newer version of \(name) on "
                                  + "GitHub, so it doesn't update it.")
            }
            return try install(name, tag: tag)
        case .remove:
            let url = Self.repositoryURL(name)
            try requireOnlyMatch(url, for: name) { $0.caseInsensitiveCompare(url) == .orderedSame }
            return try tool.command(["uninstall", url], confirmedBy: (sibling: "mint", arguments: Self.listArguments),
                                    checking: .mintAbsent(package: name, metadata: metadataPath))
        case .repair:
            throw EngineError(engine: .mint, message: "Mint repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .mint, message: "Mint can't mark packages")
        }
    }

    /// `mint install --overwrite n owner/repo@tag`, confirmed by `mint list` showing that version linked. The tag
    /// came from a lookup and is checked again here, since Mint passes it to bash.
    private func install(_ name: String, tag: String) throws -> CommandSpec {
        guard Self.isSafeTag(tag) else {
            throw EngineError(engine: .mint, message: "BrewxPort doesn't pass \(name.possessive) version tag to Mint.")
        }
        return try tool.command(["install", "--overwrite", "n", "\(name)@\(tag)"],
                                confirmedBy: (sibling: "mint", arguments: Self.listArguments),
                                checking: .mintLinked(package: name, version: tag, metadata: metadataPath))
    }

    /// `mint uninstall <name>` for a package the last listing couldn't name as `owner/repo` (R24), confirmed by
    /// `mint list` no longer showing that name. The name must be a plain one, and the one metadata URL that contains it
    /// must be the package's own: one Mint names `name` (`requireOnlyMatch`).
    private func removeByMintName(_ name: String) throws -> CommandSpec {
        guard Self.isPlainName(name) else {
            throw EngineError(engine: .mint, message: "BrewxPort doesn't pass the name \(name) to Mint's uninstall.")
        }
        try requireOnlyMatch(name, for: name) {
            Self.listName(repository: $0).caseInsensitiveCompare(name) == .orderedSame
        }
        return try tool.command(["uninstall", name], confirmedBy: (sibling: "mint", arguments: Self.listArguments),
                                checking: .mintAbsent(package: name, metadata: metadataPath))
    }

    /// Mint's uninstall removes every package whose URL contains its argument, ignoring case, and asks which when
    /// several do. So a removal goes ahead only when exactly one URL in Mint's metadata, read again now, contains
    /// `argument`, and that URL is the package's own (`isOwn`); otherwise it's refused rather than left to remove
    /// another package. The message never shows a URL.
    private func requireOnlyMatch(_ argument: String, for name: String, isOwn: (String) -> Bool) throws {
        let matching = try repositories().filter { $0.lowercased().contains(argument.lowercased()) }
        guard matching.count == 1, isOwn(matching[0]) else {
            let why = matching.contains(where: isOwn) ? "would also match another package"
                : "doesn't match \(name.possessive) own address in Mint's metadata"
            throw EngineError(engine: .mint, message: "Mint's uninstall finds packages by part of their address, and "
                              + "what BrewxPort would pass for \(name) \(why), so it doesn't remove it.")
        }
    }

    /// A name Mint lists that's safe as an argument: a letter, digit or `_`, then letters, digits and `._+-`.
    static func isPlainName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isLetterOrDigit(first) || first == "_" else { return false }
        return name.unicodeScalars.allSatisfy { isLetterOrDigit($0) || "._+-".unicodeScalars.contains($0) }
    }

    // MARK: confirming a change

    /// `ConfirmationCheck`'s answer, with the repositories in the metadata file the check names (nil when it can't be
    /// read).
    static func confirmationFailure(_ check: ConfirmationCheck, listing: String) -> String? {
        let path: String
        switch check {
        case .mintLinked(_, _, let metadata), .mintAbsent(_, let metadata): path = metadata
        }
        let repositories = (try? readFile(path)).flatMap { $0 }.flatMap { try? Self.repositories(metadata: $0) }
        return confirmationFailure(check, listing: listing, repositories: repositories)
    }

    /// `ConfirmationCheck`'s answer for Mint: nil when `listing` (`mint list`'s output) shows the package with every
    /// executable of that version linked, or doesn't show it at all; otherwise why not. A listing BrewxPort can't read
    /// confirms nothing. A listed package is the one checked by its identity (`identity`); one whose identity can't
    /// be told is never taken as linked, and always as still there.
    static func confirmationFailure(_ check: ConfirmationCheck, listing: String, repositories: [String]?) -> String? {
        guard let listed = try? listed(listing) else {
            return "BrewxPort couldn't read Mint's list of packages, so it couldn't confirm the change."
        }
        switch check {
        case .mintLinked(let package, let version, _):
            let linked = listed.contains { entry in
                identity(entry, package, repositories) == .same
                    && entry.versions.contains { $0.version == version && $0.linked && !$0.partlyLinked }
            }
            return linked ? nil : "Mint finished, but its list doesn't show \(package) \(version) linked."
        case .mintAbsent(let package, _):
            let shown = listed.contains { identity($0, package, repositories) != .other }
            return shown ? "Mint finished, but its list still shows \(package)." : nil
        }
    }

    /// Whether a listed package is the one checked.
    enum Identity: Equatable {
        case same, other, unknown
    }

    /// For an `owner/repo`: a listed package of its Mint name is it when the URL Mint printed beside it is its URL, or,
    /// without one, when the one metadata URL of that name is (ignoring case, as GitHub and Mint do). Without the
    /// metadata, or with no or several URLs of that name, it's `unknown`. A package named without an owner (Mint's own
    /// name, R24) is matched by that name: its removal already required the one URL containing it to be its own.
    static func identity(_ entry: Listed, _ package: String, _ repositories: [String]?) -> Identity {
        guard package.contains("/") else {
            return entry.name.caseInsensitiveCompare(package) == .orderedSame ? .same : .other
        }
        let url = repositoryURL(package)
        guard entry.name.caseInsensitiveCompare(listName(repository: url)) == .orderedSame else { return .other }
        if let printed = entry.repository {
            return printed.caseInsensitiveCompare(url) == .orderedSame ? .same : .other
        }
        guard let named = repositories?.filter({ listName(repository: $0) == entry.name }), named.count == 1 else {
            return .unknown
        }
        return named[0].caseInsensitiveCompare(url) == .orderedSame ? .same : .other
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .mint, kind: .tool, name: name) }

    /// What the last `detect()`, listing, check and search found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedFolders: (install: URL, bin: URL)?
        private var tools: [String: Tool] = [:]
        private var newer: [String: String] = [:]
        private var discovered: [String: String] = [:]
        private var notChecked: [String: String] = [:]

        var folders: (install: URL, bin: URL)? { lock.withLock { detectedFolders } }
        var unchecked: [String: String] { lock.withLock { notChecked } }
        var unmappedReasons: [String: String] {
            lock.withLock { tools.compactMapValues(\.unmapped) }
        }

        func detected(install: URL, bin: URL) { lock.withLock { detectedFolders = (install, bin) } }
        func forgetFolders() { lock.withLock { detectedFolders = nil } }

        func listed(_ found: [Tool]) {
            let map = Dictionary(found.map { ($0.name, $0) }) { first, _ in first }
            lock.withLock { tools = map }
        }

        func checked(updates: [String: String], couldntCheck: [String: String]) {
            lock.withLock {
                newer = updates
                notChecked = couldntCheck
            }
        }

        func clearCouldntCheck() { lock.withLock { notChecked = [:] } }

        func found(_ name: String, newest: String) { lock.withLock { discovered[name] = newest } }

        func tool(_ name: String) -> Tool? { lock.withLock { tools[name] } }
        /// The newer tag the last outdated check found for `name`.
        func update(_ name: String) -> String? { lock.withLock { newer[name] } }
        /// The newest stable tag a search found for `name`.
        func newest(_ name: String) -> String? { lock.withLock { discovered[name] } }
    }
}

// MARK: Task 10: commands

extension MintEngine: ExecutableNaming {
    /// The executables the last listing showed for the package (Ink's `ink-cli`). Mint doesn't name the one that has
    /// the package's own name, so that's the repository's name; nil for a package the listing didn't show.
    public func executables(of name: String) -> [String]? {
        guard let listed = state.tool(name) else { return nil }
        return listed.executables ?? [String(name.split(separator: "/").last ?? Substring(name))]
    }
}
