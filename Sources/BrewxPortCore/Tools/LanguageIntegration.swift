import Foundation

// What the language engines tell the rest of BrewxPort beyond their packages (Plan 9 Task 10): where they write and
// whether this account can, which Homebrew runtimes their tools run on, how to repair those tools, and which
// commands a tool put on disk.

// MARK: Where an engine writes

/// Whether this account can change what a language engine installed: a real access check (access(2) with W_OK) on
/// each folder the engine writes, never a guess from who owns it. A folder that isn't there yet (`~/.cargo/bin` before
/// the first install) counts as its nearest existing parent folder, unless the way there goes through a link to
/// something that isn't there: nothing can be written through that.
public enum InstallAccess {
    /// The app's check, on this account.
    public static func isWritable(_ path: String) -> Bool {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: url.path) { return access(url.path, W_OK) == 0 }
            if isDanglingLink(url.path) { return false }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }

    /// A symbolic link to something that isn't there (or a loop of links).
    static func isDanglingLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// The first folder from `path` up, among those that aren't there, that is a link to something that isn't there;
    /// nil when there's none.
    static func danglingLink(in path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path) {
            if isDanglingLink(url.path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// The first of `folders` that `isWritable` refuses; nil when it allows them all.
    static func firstUnwritable(_ folders: [URL], isWritable: (String) -> Bool) -> URL? {
        folders.first { !isWritable($0.path) }
    }

    /// `path` with the home folder shown as `~`, as people write it.
    public static func shown(_ path: String, home: String) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The engine page's line for a folder this account can't write: what it means and, for npm, the official fix
    /// (a global folder of the person's own).
    static func reason(_ engine: EngineID, folder: URL, home: String) -> String {
        let shown = shown(folder.path, home: home)
        if let link = danglingLink(in: folder.path) {
            return "\(engine.displayName) installs tools into \(shown), but \(Self.shown(link, home: home)) is a link to "
                + "a folder that isn't there, so BrewxPort leaves its tools as they are."
        }
        switch engine {
        case .npm:
            return "npm installs tools into \(shown), which your account can't change. Give npm a folder of your own "
                + "with npm config set prefix ~/.npm-global, then add ~/.npm-global/bin to your PATH."
        default:
            return "\(engine.displayName) installs tools into \(shown), which your account can't change, so BrewxPort "
                + "leaves its tools as they are."
        }
    }
}

/// What a language engine's last detect found about the folders it writes (`InstallLocationReporting.readOnlyReason`),
/// shared by copies of the engine. Until a detect has looked, nothing is refused.
final class InstallAccessState: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    private let isWritable: @Sendable (String) -> Bool

    /// `isWritable` is `InstallAccess.isWritable` in the app; demo mode and tests pass their own.
    init(isWritable: @escaping @Sendable (String) -> Bool) {
        self.isWritable = isWritable
    }

    var readOnlyReason: String? { lock.withLock { reason } }

    /// After a detect: refuses changes when one of `folders` can't be written, saying which, or naming `named` instead
    /// (npm's prefix, rather than the `lib/node_modules` inside it). No folders (the engine isn't there, or didn't say
    /// where it writes) refuses nothing.
    func checked(_ engine: EngineID, folders: [URL], home: String, named: URL? = nil) {
        let found = InstallAccess.firstUnwritable(folders, isWritable: isWritable)
            .map { InstallAccess.reason(engine, folder: named ?? $0, home: home) }
        lock.withLock { reason = found }
    }

    /// After a detect that found the engine read-only whatever its folders say (macOS's own Ruby), or nil.
    func readOnly(_ text: String?) {
        lock.withLock { reason = text }
    }

    /// Refuses an install, update, removal or repair while the last detect found the engine read-only: the backstop
    /// behind the pages, which never offer them then.
    func requireWritable(for op: PackageOperation, engine: EngineID) throws {
        switch op {
        case .install, .upgrade, .remove, .repair:
            if let reason = readOnlyReason { throw EngineError(engine: engine, message: reason) }
        case .markRequested, .markDependency:
            return
        }
    }
}

// MARK: Version managers

/// Version managers that switch which Node or Ruby the login shell runs: npm's globals and RubyGems' gems belong to
/// that one version (the design: "for version managers (nvm, rbenv, asdf, mise), that the list is for the current
/// default version"). Commands run from the home folder, so a shim's version is the default one.
public enum VersionManagers {
    /// The engine page's line when `executable` (the engine's path as it was found) is under a version manager's
    /// folder: "The list is for nvm's current default Node. Other Node versions keep their own tools." Nil otherwise,
    /// and for engines whose tools don't belong to one runtime version.
    public static func note(for engine: EngineID, executable: String) -> String? {
        let runtime: String
        let tools: String
        let managers: [(name: String, folders: [String])]
        switch engine {
        case .npm:
            (runtime, tools) = ("Node", "tools")
            managers = [("nvm", ["/.nvm/versions/node/", "/nvm/versions/node/"]), ("fnm", ["/fnm/", "/fnm_multishells/"]),
                        ("asdf", ["/.asdf/"]), ("mise", ["/mise/installs/", "/mise/shims/"])]
        case .gem:
            (runtime, tools) = ("Ruby", "gems")
            managers = [("rbenv", ["/.rbenv/"]), ("asdf", ["/.asdf/"]), ("mise", ["/mise/installs/", "/mise/shims/"])]
        case .homebrew, .nanobrew, .macports, .mas, .pipx, .uv, .cargo, .bun, .mint:
            return nil
        }
        guard let manager = managers.first(where: { $0.folders.contains(where: executable.contains) }) else {
            return nil
        }
        return "The list is for \(manager.name)'s current default \(runtime). Other \(runtime) versions keep their "
            + "own \(tools)."
    }
}

// MARK: Runtimes

/// One Homebrew runtime a language engine's tools run on, and which of them (design option A: a Ruby minor update, a
/// Node major update, or a change to a python@3.x breaks them until they're repaired).
public struct RuntimeUse: Hashable, Sendable {
    /// The Homebrew formula: `node`, `ruby`, `python@3.15`.
    public let formula: String
    /// The tools that run on it, by name; empty when all of the engine's tools do (npm's, RubyGems').
    public let tools: [String]
    /// R29: the tools among `tools` known to survive a patch update of the formula: their environment points at
    /// Homebrew's `opt/<formula>` or `bin` link, which follows the update (`VenvConfig.followsPatchUpdates`). The rest
    /// (pinned to one Cellar copy, unreadable, anywhere else) break when that copy goes. Empty by default: the careful
    /// reading.
    public let patchSafeTools: [String]

    public init(formula: String, tools: [String] = [], patchSafeTools: [String] = []) {
        self.formula = formula
        self.tools = tools
        self.patchSafeTools = patchSafeTools
    }
}

/// Reads one file of a language engine's own (uv's receipt, a venv's `pyvenv.cfg`) by path: nil when there's no such
/// file; throws when it's there but can't be read. Demo mode and tests pass their own, so neither reads this Mac's.
public typealias ToolFileReader = @Sendable (_ path: String) throws -> Data?

public enum ToolFiles {
    /// The app's reader: the file on disk.
    public static let read: ToolFileReader = { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// The app's check that something is at `path` itself: a link counts even when what it points to is gone.
    public static let entryExists: ToolPathCheck = { path in
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
}

/// Whether something is at a path of a tool's own (`ToolFiles.entryExists`); demo mode and tests pass their own.
public typealias ToolPathCheck = @Sendable (_ path: String) -> Bool

/// A Python virtual environment's `pyvenv.cfg` (R29): its `home` is the folder of the Python it was made with, as it
/// was named then.
public enum VenvConfig {
    /// The `home = …` value; nil when there's none.
    public static func home(_ text: String) -> String? { value("home", in: text) }

    /// The venv's Python version: `version_info` as uv writes it (`3.15.2`), else `version` as Python's `venv` module
    /// does; nil unless it's numbers with at least a minor part (R41).
    public static func version(_ text: String) -> String? {
        guard let version = value("version_info", in: text) ?? value("version", in: text) else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            return nil
        }
        return version
    }

    /// `version`'s `major.minor` (`3.15`), the Python a uv repair asks for (R41).
    public static func minorVersion(_ text: String) -> String? {
        version(text).map { $0.split(separator: ".").prefix(2).joined(separator: ".") }
    }

    private static func value(_ key: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            return nonBlank(String(parts[1]))
        }
        return nil
    }

    /// Whether `home` is one of Homebrew's folders: anything under `/opt/homebrew`, and the folders Homebrew owns under
    /// `/usr/local` (`Cellar`, `opt`, `Frameworks`, `bin`). A readable `home` anywhere else (uv's own Python, pyenv's,
    /// python.org's, the system's) means the venv doesn't run on a Homebrew Python at all.
    public static func isHomebrew(home: String) -> Bool {
        var path = home
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/opt/homebrew" || path.hasPrefix("/opt/homebrew/") { return true }
        return ["Cellar", "opt", "Frameworks", "bin"].contains { folder in
            path == "/usr/local/" + folder || path.hasPrefix("/usr/local/" + folder + "/")
        }
    }

    /// A venv or tool name, as pipx or uv printed it, that's safe to use as one folder name in a path: not empty, no
    /// `/`, no `..`, and not starting with `.`. Any other name's `pyvenv.cfg` isn't read (its venv counts as unknown).
    public static func isPlainFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.hasPrefix(".")
    }

    /// Whether a venv whose `home` is this survives a patch update of Homebrew's `formula`: it names Homebrew's
    /// `opt/<formula>` link (or something inside it) or Homebrew's `bin`, both of which Homebrew points at the new copy.
    /// A `home` inside one Cellar copy (`Cellar/python@3.15/3.15.2/…`) goes with that copy, and so does one through
    /// Homebrew's `Frameworks` (it resolves through the formula's versioned folder); anything else is unknown: none of
    /// those counts.
    public static func followsPatchUpdates(home: String, formula: String) -> Bool {
        var path = home
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return HomebrewFormula.prefixes.contains { prefix in
            let opt = prefix + "/opt/" + formula
            return path == opt || path.hasPrefix(opt + "/") || path == prefix + "/bin"
        }
    }
}

/// A language engine whose tools run on a Homebrew runtime: npm on `node`, RubyGems on `ruby`, pipx's and uv's tools
/// on a `python@3.x`.
public protocol RuntimeReporting: Sendable {
    /// The Homebrew runtimes its tools run on now. npm and RubyGems answer from their last detect; pipx and uv ask
    /// for their tools' Pythons, and throw when they can't tell.
    func runtimeUses() async throws -> [RuntimeUse]
}

/// The Homebrew formula a file belongs to, read from its path: `<prefix>/Cellar/<formula>/…` or
/// `<prefix>/opt/<formula>/…` under Homebrew's prefixes. The path's links are followed first (Homebrew's `bin/node`
/// links into the Cellar), then the path as it's written. Nil for anything else.
public enum HomebrewFormula {
    static let prefixes = ["/opt/homebrew", "/usr/local"]

    public static func owning(_ path: String, realPath: (String) -> String? = ToolLocator.realPath) -> String? {
        for candidate in [realPath(path), path].compactMap({ $0 }) {
            for prefix in prefixes {
                for folder in ["/Cellar/", "/opt/"] where candidate.hasPrefix(prefix + folder) {
                    let rest = candidate.dropFirst(prefix.count + folder.count)
                    if let name = rest.split(separator: "/").first, !name.isEmpty { return String(name) }
                }
            }
        }
        return nil
    }

    /// `python@3.15` for a Python `3.15.2`; nil for a version without a minor part.
    public static func python(version: String) -> String? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2, parts[0] == "3", Int(parts[1]) != nil else { return nil }
        return "python@3.\(parts[1])"
    }
}

// MARK: Repair

/// One step of repairing an engine's tools after their runtime changed.
public struct RepairCommand: Equatable, Sendable {
    /// The tool it repairs; nil when it repairs every tool at once (`npm rebuild -g`, `pipx reinstall-all`).
    public let tool: String?
    public let spec: CommandSpec

    public init(tool: String?, spec: CommandSpec) {
        self.tool = tool
        self.spec = spec
    }
}

/// A language engine that can repair its tools once the runtime they run on changed: npm rebuilds them, pipx and uv
/// reinstall them, RubyGems installs them again (a new Ruby minor version has a gem folder of its own).
public protocol ToolRepairing: Sendable {
    /// The steps, in order. `tools` names the tools to repair, for an engine that repairs one at a time (uv, RubyGems):
    /// Installed's tools before the runtime changed and since, since a tool whose runtime is gone may not be listed any
    /// more. A tool the engine won't repair automatically is left out, and `repairRefusals` says why. Throws when it
    /// can't build them (nothing to repair, the engine isn't there or its folders aren't writable).
    func repairCommands(for tools: [String]) throws -> [RepairCommand]
    /// The tools among `tools` that `repairCommands` leaves out, each with one line saying why (R28: uv's tool
    /// installed from git); empty for an engine that repairs everything at once.
    func repairRefusals(for tools: [String]) -> [String: String]
}

// MARK: Executables

/// A language engine that can say which commands one of its tools put in its bin folder (Cargo's `ripgrep` puts `rg`
/// there), from its own records, without a network lookup.
public protocol ExecutableNaming: Sendable {
    /// Nil when the engine doesn't know.
    func executables(of name: String) -> [String]?
}

/// The commands a node package declares (`bin` in its package.json: one string, named after the package, or a map of
/// names). For npm's and Bun's global packages.
enum NodePackageExecutables {
    static func read(packageFolder: URL, name: String) -> [String]? {
        let file = packageFolder.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let names: [String]
        switch object["bin"] {
        case is String:
            names = [String(name.split(separator: "/").last ?? Substring(name))]
        case let map as [String: Any]:
            names = map.keys.sorted()
        default:
            return nil
        }
        return names.filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }
    }
}
