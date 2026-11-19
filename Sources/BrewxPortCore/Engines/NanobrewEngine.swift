import Foundation

/// nanobrew (`nb`), driven through its `--json` output (needs nb 0.1.216 or newer).
/// BrewxPort never runs nb as root: casks that need root go through Homebrew instead.
public struct NanobrewEngine: Engine {
    public let id: EngineID = .nanobrew
    public let capabilities: EngineCapabilities = [.casks, .jsonOutput]

    private let runner: CommandRunning
    private let executable: URL?

    public var executableURL: URL? { executable }

    public init(runner: CommandRunning, executable: URL?) {
        self.runner = runner
        self.executable = executable
    }

    // MARK: JSON shape (schema 1)

    private struct SchemaProbe: Decodable {
        let schema: Int
    }

    private struct Document: Decodable {
        let packages: [Entry]
    }

    private struct Entry: Decodable {
        let name: String
        let kind: String
        let version: String?
        let desc: String?
        let installed: InstalledField?
        let latest: String?
    }

    /// `outdated` has `installed` as a version string; `search` has it as a Bool.
    private enum InstalledField: Decodable {
        case text(String), flag(Bool)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .flag(b) } else { self = .text(try c.decode(String.self)) }
        }

        var text: String? {
            if case .text(let s) = self { return s }
            return nil
        }
    }

    private static let upgradeHint = "BrewxPort needs nanobrew 0.1.216 or newer for JSON output"

    // MARK: detect

    public func detect() async -> EngineStatus {
        await detectStatus(runner: runner, executable: executable, arguments: ["help"]) { stdout in
            // nb has no version command. The first line of help is "nanobrew v0.1.216 - The fastest package manager",
            // with ANSI colour codes around the words.
            guard let first = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let plain = String(first).replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            guard let range = plain.range(of: "^nanobrew v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
            return String(plain[range].dropFirst("nanobrew v".count))
        }
    }

    // MARK: search / installed / outdated

    public func search(_ query: String) async throws -> [Package] {
        // nb doesn't honour `--` (it searches for the literal "--"), and it never reads the query as an option.
        let args = try searchArguments(["search", "--json"], query: query, engine: .nanobrew, separator: false)
        return try await fetch(args, "search").compactMap { entry in
            guard let kind = Self.kind(entry.kind) else { return nil }
            return Package(id: ref(entry.name, kind), displayName: entry.name,
                           latestVersion: entry.version, summary: Self.nonEmpty(entry.desc))
        }
    }

    public func listInstalled() async throws -> [Package] {
        try await fetch(["list", "--json"], "list").compactMap { entry in
            guard let kind = Self.kind(entry.kind) else { return nil }
            return Package(id: ref(entry.name, kind), displayName: entry.name, installedVersion: entry.version)
        }
    }

    public func listOutdated() async throws -> [Package] {
        try await fetch(["outdated", "--json"], "outdated").compactMap { entry in
            guard let kind = Self.kind(entry.kind) else { return nil }
            return Package(id: ref(entry.name, kind), displayName: entry.name,
                           installedVersion: entry.installed?.text, latestVersion: entry.latest)
        }
    }

    // MARK: info

    private struct InfoEntry: Decodable {
        struct Artifact: Decodable { let type: String? }
        let desc: String?
        let homepage: String?
        let version: String?
        let dependencies: [String]?
        let artifacts: [Artifact]?
    }

    private struct InfoDocument: Decodable {
        let packages: [InfoEntry]
    }

    /// `nb info --json <formula>` and `nb info --cask --json <app>`. The cask JSON lists artifacts (`pkg`, `app`, ...),
    /// so `installerNeedsRoot` is known for casks; the formula JSON has `dependencies` but no installed version.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .nanobrew else {
            throw EngineError(engine: .nanobrew, message: "Package belongs to a different engine")
        }
        guard ref.kind == .formula || ref.kind == .cask else {
            throw EngineError(engine: .nanobrew, message: "nanobrew has no \(ref.kind.rawValue) packages")
        }
        let name = try packageNameArguments([ref], engine: .nanobrew)[0]
        let args = ref.kind == .cask ? ["info", "--cask", "--json", name] : ["info", "--json", name]
        let data = try await fetchData(args, "info")
        let doc: InfoDocument
        do { doc = try JSONDecoder().decode(InfoDocument.self, from: data) } catch {
            throw EngineError(engine: .nanobrew, message: "Couldn't read nb info output (schema 1): \(String(describing: error))")
        }
        guard let e = doc.packages.first else {
            throw EngineError(engine: .nanobrew, message: "nb had no information for \(name)")
        }
        let isCask = ref.kind == .cask
        return PackageDetails(
            ref: ref, summary: nonBlank(e.desc), homepage: webURL(e.homepage), latestVersion: nonBlank(e.version),
            dependencies: isCask ? nil : e.dependencies,
            installerNeedsRoot: isCask ? e.artifacts.map { list in
                list.contains { $0.type == "pkg" || $0.type == "installer" }
            } : nil)
    }

    // MARK: commands

    /// Formulae never need root. nb never calls sudo itself, so casks whose installers need root fail
    /// under nb and must be routed to Homebrew (ruling R11; private/spikes/2026-11-sudo-askpass.md, nanobrew casks).
    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        ref.kind == .cask ? .sometimes : .never
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard refs.allSatisfy({ $0.engine == .nanobrew }) else {
            throw EngineError(engine: .nanobrew, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .nanobrew, message: "nanobrew can't install a specific version")
        }
        guard options.variants.isEmpty else {
            throw EngineError(engine: .nanobrew, message: "nanobrew has no variants")
        }
        let names = try packageNameArguments(refs, engine: .nanobrew)
        let casks = refs.filter { $0.kind == .cask }.count
        guard casks == 0 || casks == refs.count else {
            throw EngineError(engine: .nanobrew, message: "Can't mix formulae and casks in one command")
        }
        let exe = try requireExecutable()
        let verb: String
        switch op {
        case .install: verb = "install"
        case .upgrade: verb = "upgrade"
        case .remove: verb = "remove"
        }
        let flag = casks > 0 ? ["--cask"] : []
        return CommandSpec(executable: exe, arguments: [verb] + flag + options.extraArgs + names, needsRoot: false)
    }

    // MARK: helpers

    private func fetch(_ args: [String], _ what: String) async throws -> [Entry] {
        let data = try await fetchData(args, what)
        if data.isEmpty { return [] }
        do {
            return try JSONDecoder().decode(Document.self, from: data).packages
        } catch {
            throw EngineError(engine: .nanobrew, message: "Couldn't read nb \(what) output (schema 1): \(String(describing: error))")
        }
    }

    /// Runs nb and returns its JSON (schema 1) as data; empty data for blank output.
    private func fetchData(_ args: [String], _ what: String) async throws -> Data {
        let exe = try requireExecutable()
        let result = try await runner.run(exe, args)
        guard result.exitCode == 0 else {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = err.isEmpty ? "" : ": \(String(err.prefix(300)))"
            throw EngineError(engine: .nanobrew, message: "nb \(what) failed (exit \(result.exitCode))\(suffix)")
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if what == "info" { throw EngineError(engine: .nanobrew, message: "nb info printed nothing") }
            return Data()
        }
        let data = Data(text.utf8)
        // Schema first: older nb prints plain text (no JSON, no schema), newer nb may print another schema.
        guard let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data) else {
            throw EngineError(engine: .nanobrew, message: "Couldn't read nb \(what) output. \(Self.upgradeHint).")
        }
        guard probe.schema == 1 else {
            throw EngineError(engine: .nanobrew, message: "nb \(what): unsupported nanobrew output schema \(probe.schema)")
        }
        return data
    }

    /// nb also lists `deb` packages; BrewxPort has no kind for them.
    private static func kind(_ raw: String) -> PackageKind? {
        switch raw {
        case "formula": return .formula
        case "cask": return .cask
        default: return nil
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    private func ref(_ name: String, _ kind: PackageKind) -> PackageRef {
        PackageRef(engine: .nanobrew, kind: kind, name: name)
    }

    private func requireExecutable() throws -> URL {
        guard let executable else {
            throw EngineError(engine: .nanobrew, message: "nanobrew isn't installed")
        }
        return executable
    }
}
