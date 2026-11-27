import Foundation

/// Cargo's installed crates: Rust command-line tools that `cargo install` builds from source into the install root's
/// `bin` folder. Always as the user, never as root (Plan 9). Found from the login shell's PATH first, then the fixed
/// folders (`fixedFolders`).
///
/// - The install root is CARGO_INSTALL_ROOT, else `install.root` in CARGO_HOME's `config.toml` (an absolute path,
///   R42), else CARGO_HOME (both variables from the login shell), else `~/.cargo`.
/// - Installed crates come from cargo's own record in the install root (`.crates2.json`), read without running cargo:
///   `cargo install --list` takes cargo's lock, so it waits for a running build, and it creates the record when
///   there's none. cargo is asked only when the record can't be used (`recorded`).
/// - Newer versions come from crates.io's sparse index (`indexURL`), one file per crate: the newest version that isn't
///   yanked, and not a pre-release unless the installed one is. A version whose `rust_version` is newer than the Rust
///   beside cargo is held back (`needsNewerRust`): cargo would refuse to build it.
/// - Only crates installed from crates.io are checked and updated. Git and path installs and crates from another
///   registry are listed and can be removed, never offered as updates. Their source (a folder of the user's, or a git
///   URL that can carry a token) is never kept, logged or shown: only its kind (`Source`).
/// - An upgrade is `cargo install` again with the features, profile and target cargo recorded for the crate
///   (`options(_:)`), so nothing it was installed with silently changes; a crate whose recorded options aren't safe
///   to pass back isn't updated (`unsafeOptions`). It passes the version the outdated check offered as
///   `--version =<it>` (R36), so what cargo installs is what Updates showed, and never when that version is no newer
///   than what's installed by then (R42). A crate installed with `--bin` for some of its executables keeps just those
///   (R42: the record names them; crates.io's API says which the version has).
/// - Discover runs `cargo search`; details come from crates.io's API, with each crate's executables.
public struct CargoEngine: Engine, InstallLocationReporting {
    public let id: EngineID = .cargo
    /// `cargo search` and `install --list` print text; the record and the index are read directly.
    public let capabilities: EngineCapabilities = []

    /// Reads one file of cargo's record by path: nil when there's no such file; throws when it's there but can't be
    /// read. Demo mode and tests pass their own, so neither reads this Mac's `~/.cargo`.
    public typealias RecordReader = @Sendable (_ path: String) throws -> Data?

    /// The app's reader: the file on disk.
    public static let readFile: RecordReader = { path in
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// `cargo search`'s options before the query, as captured: 20 results, no colours.
    static let searchArguments = ["search", "--limit", "20", "--color", "never"]
    /// crates.io lookups at a time, for an outdated check.
    static let concurrentLookups = 4
    /// How an outdated check paces its crates.io API lookups (R42's executables, `/api/v1`): one at a time, at least
    /// `spacing` apart (crates.io's crawler policy asks for at most one request a second, and a refused one, 429,
    /// would quietly drop a recorded `--bin` subset), within `budget` from the first lookup, so a slow crates.io never
    /// holds the whole check up to its time limit: crates not looked up by then keep a plain upgrade. `now` and
    /// `sleep` are the clock the spacing and the budget are counted on; a lookup that would run past the budget is
    /// cut off on the real clock. The sparse index (index.crates.io) has no such limit. Demo mode and tests pass their
    /// own.
    ///
    /// The budget is also cut to what the whole check has left: `checkLimit` (the catalog's limit for one engine's
    /// check, `BrewxPortTimeouts.engineQuery`) from when the check started, less `handOver`, so the index lookups and
    /// these together never run the check past it.
    public struct APIPacing: Sendable {
        public var spacing: Duration
        public var budget: Duration
        /// How long the whole check may take before the catalog gives up on it, counted from its start.
        public var checkLimit: Duration
        public var now: @Sendable () -> ContinuousClock.Instant
        public var sleep: @Sendable (Duration) async throws -> Void

        /// Kept back from `checkLimit`: the lookups end this long before it, so the check's answer is in before the
        /// catalog's timer runs out.
        public static let handOver: Duration = .seconds(2)

        public init(spacing: Duration, budget: Duration, checkLimit: Duration = BrewxPortTimeouts.engineQuery,
                    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
            self.spacing = spacing
            self.budget = budget
            self.checkLimit = checkLimit
            self.now = now
            self.sleep = sleep
        }

        /// The app's: a second apart, 20 seconds a check (a Cargo check may take a minute in all).
        public static let live = APIPacing(spacing: .seconds(1), budget: .seconds(20))
    }
    /// The sources cargo writes for crates.io: the git index's URL, and the sparse index's.
    static let cratesIOSources: Set<String> = [
        "registry+https://github.com/rust-lang/crates.io-index", "sparse+https://index.crates.io/",
    ]

    private let tool: LanguageTool
    private let registry: any RegistryFetching
    private let readRecord: RecordReader
    private let pacing: APIPacing
    private let home: String
    private let state = State()
    private let access: InstallAccessState

    public var executableURL: URL? { tool.executable }

    /// Why this account can't change Cargo's crates: the last detect found the install root or its bin folder not
    /// writable (an earlier `sudo cargo install` leaves them owned by root).
    public var readOnlyReason: String? { access.readOnlyReason }

    /// The install root as the last `detect()` found it: where cargo keeps its record of installed crates.
    public var installLocation: URL? { state.root }

    /// The install root's `bin` folder, where `cargo install` puts executables.
    public var binLocation: URL? { state.root?.appendingPathComponent("bin", isDirectory: true) }

    /// The crates whose newest version needs a newer Rust than the one beside cargo, as the last outdated check found
    /// them: name → the Rust version it needs. They aren't offered as updates; the check holds them back
    /// (`checkOutdated`'s `held`, "Needs Rust 1.96").
    public var needsNewerRust: [String: String] { state.needsNewerRust }

    /// The crates from crates.io whose recorded install options BrewxPort won't pass back to cargo (`options(_:)`), as
    /// the last listing found them: name → a one-line reason. They aren't offered as updates or upgraded; one with a
    /// newer version is held back with that reason (`checkOutdated`'s `held`).
    public var unsafeOptions: [String: String] { state.unsafeOptions }

    /// The app's cargo: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `registry`
    /// reads crates.io; `base` is the environment every command starts from; `readRecord` reads cargo's record.
    public init(runner: CommandRunning, registry: any RegistryFetching, loginShell: @escaping LoginShellContextProvider,
                arch: Arch = .current, base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                readRecord: @escaping RecordReader = CargoEngine.readFile,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable,
                apiPacing: APIPacing = .live) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .cargo, name: "cargo", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.registry = registry
        self.readRecord = readRecord
        pacing = apiPacing
        self.home = home
        access = InstallAccessState(isWritable: isWritable)
    }

    /// cargo at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed.
    /// Its folders count as writable unless `isWritable` says otherwise.
    public init(runner: CommandRunning, registry: any RegistryFetching, executable: URL?,
                captured: [String: String] = [:], base: [String: String] = ProcessRunner.baseEnvironment,
                readRecord: @escaping RecordReader = CargoEngine.readFile,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true },
                apiPacing: APIPacing = .live) {
        tool = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.registry = registry
        self.readRecord = readRecord
        pacing = apiPacing
        home = LanguageTool.home(base)
        access = InstallAccessState(isWritable: isWritable)
    }

    // MARK: finding cargo

    /// Where cargo is looked for after the login shell's PATH: Homebrew's `rust` (this Mac's own prefix first),
    /// Homebrew's keg-only `rustup`, MacPorts', nanobrew's, then rustup's own folder (CARGO_HOME's bin, then
    /// `~/.cargo/bin`) and the version managers' shims (asdf, mise, Nix).
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        let prefixes: [String] = arch == .arm64 ? ["/opt/homebrew", "/usr/local"] : ["/usr/local", "/opt/homebrew"]
        var folders: [String] = prefixes.map { $0 + "/bin" }
        folders += prefixes.map { $0 + "/opt/rustup/bin" }
        folders += ["/opt/local/bin", "/opt/nanobrew/prefix/bin"]
        if let cargoHome = captured["CARGO_HOME"] { folders.append(cargoHome + "/bin") }
        folders.append(home + "/.cargo/bin")
        folders += [home + "/.asdf/shims", home + "/.local/share/mise/shims", home + "/.nix-profile/bin"]
        return folders
    }

    // MARK: Set Up

    /// The package manager Cargo's Set Up installed rustup from, which decides its toolchain step.
    public enum RustupSource: Sendable, Equatable {
        /// Homebrew's keg-only `rustup` under this prefix (`/opt/homebrew`, or `/usr/local` on an Intel Mac): nothing
        /// is linked, so `rustup` and the cargo proxy (`fixedFolders`) are in `<prefix>/opt/rustup/bin`.
        case homebrew(prefix: String)
        /// MacPorts' `rustup` port, which installs only `/opt/local/bin/rustup-init`.
        case macports
        /// A rustup that's already there without a toolchain (the person's own in `~/.cargo/bin`, or Homebrew's keg
        /// left so by a toolchain step that failed): its `default stable`, and no second rustup (R31).
        case installed(URL)
    }

    /// Cargo's Set Up step after rustup's package is installed: Rust's stable toolchain, as the user, with Cargo's
    /// environment (`ToolEnvironment.make`: the executable's folder first on PATH, CARGO_HOME, CARGO_INSTALL_ROOT and
    /// RUSTUP_HOME from the login shell, NO_COLOR) on `base`, from the home folder.
    ///
    /// - Homebrew, or a rustup that's already there: `rustup default stable`, which installs the stable toolchain and
    ///   makes it the default.
    /// - MacPorts: its port has no `rustup`, only `rustup-init`: `-y` (stdin is closed), `--no-modify-path` (BrewxPort
    ///   never edits the shell's startup files without a click: the PATH note's Add to PATH does) and the stable
    ///   toolchain. It puts rustup and the cargo proxy in CARGO_HOME's `bin` (`~/.cargo/bin`).
    ///
    /// Neither downloads or runs an installer script: both run the rustup the package manager built, which fetches the
    /// toolchain itself.
    public static func toolchainSetup(from source: RustupSource, captured: [String: String],
                                      base: [String: String] = ProcessRunner.baseEnvironment) -> CommandSpec {
        let executable: URL
        let arguments: [String]
        switch source {
        case .homebrew(let prefix):
            executable = URL(fileURLWithPath: prefix + "/opt/rustup/bin/rustup")
            arguments = ["default", "stable"]
        case .macports:
            executable = URL(fileURLWithPath: "/opt/local/bin/rustup-init")
            arguments = ["-y", "--no-modify-path", "--default-toolchain", "stable"]
        case .installed(let rustup):
            executable = rustup
            arguments = ["default", "stable"]
        }
        var environment = ToolEnvironment.make(for: .cargo, executable: executable, captured: captured, base: base)
        // Cargo's commands run with RUSTUP_AUTO_INSTALL=0, so a rustup proxy never downloads a toolchain behind
        // BrewxPort's back. This one step is the exception: installing the toolchain is its purpose, and the person
        // asked for it with Set Up.
        environment["RUSTUP_AUTO_INSTALL"] = "1"
        return CommandSpec(executable: executable, arguments: arguments, needsRoot: false, environment: environment,
                           workingDirectory: LanguageTool.home(base))
    }

    // MARK: detect

    /// cargo's version, then the install root for `installLocation`. rustup's cargo without a toolchain says so
    /// (RUSTUP_AUTO_INSTALL=0 stops it downloading one), which makes Cargo unusable.
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { Self.version($0, of: "cargo") }
        var root: URL?
        if case .present = status { root = URL(fileURLWithPath: installRoot, isDirectory: true) }
        state.detected(root: root)
        access.checked(.cargo, folders: root.map { [$0, $0.appendingPathComponent("bin", isDirectory: true)] } ?? [],
                       home: home)
        return status
    }

    /// The version in `cargo --version`'s or `rustc --version`'s first line: `cargo 1.100.0 (3acc79c0c 2026-11-05)`.
    static func version(_ output: String, of name: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let words = line.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == name, EcosystemVersion.isValid(String(words[1]), scheme: .semver)
        else { return nil }
        return String(words[1])
    }

    /// A Rust version without its pre-release part: a nightly 1.96.0 meets a crate's `rust_version` of 1.96.
    static func release(_ version: String) -> String {
        String(version.prefix { $0 != "-" && $0 != "+" })
    }

    /// Where `cargo install` puts crates and its record: CARGO_INSTALL_ROOT, else `install.root` in CARGO_HOME's
    /// `config.toml` (R42: cargo honours it, `Fixtures/cargo/t13-config-root-*`), else CARGO_HOME, else `~/.cargo`.
    private var installRoot: String {
        if let root = tool.variable("CARGO_INSTALL_ROOT") { return root }
        let cargoHome = tool.variable("CARGO_HOME") ?? home + "/.cargo"
        let config = (try? readRecord(cargoHome + "/config.toml")).flatMap { $0 }
        return config.flatMap { Self.configRoot(String(decoding: $0, as: UTF8.self)) } ?? cargoHome
    }

    /// `root` in the `[install]` table of a cargo `config.toml`, read with the TOML subset uv's receipts use, from that
    /// table's lines only (cargo's other tables can hold numbers). Nil unless it's an absolute path: cargo reads a
    /// relative one against the config's folder, which BrewxPort doesn't follow.
    static func configRoot(_ text: String) -> String? {
        var lines: [Substring] = []
        var inInstall = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inInstall = trimmed.split(separator: "#", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces)
                    == "[install]"
            }
            if inInstall { lines.append(line) }
        }
        guard !lines.isEmpty, let tables = TOMLSubset.parse(lines.joined(separator: "\n")),
              let root = tables["install"]?["root"]?.string, root.hasPrefix("/") else { return nil }
        return root
    }

    // MARK: installed crates

    /// Where an installed crate came from. Only the kind is kept: the source itself names a folder of the user's or a
    /// repository, whose URL can carry a token.
    enum Source: Equatable, Sendable {
        case cratesIO
        /// Another registry's crate, which BrewxPort doesn't check.
        case otherRegistry
        /// A git repository, a local folder or anything else that isn't a registry: never checked or updated.
        case notRegistry
    }

    /// One installed crate, as cargo's record or `install --list` has it.
    struct Crate: Equatable, Sendable {
        let name: String
        let version: String
        let source: Source
        /// Its executables (ripgrep's `rg`).
        let bins: [String]
        /// How many installs share the name: cargo keeps two versions with different executables apart.
        var copies = 1
        /// The options it was installed with, which an upgrade passes again (`options(_:)`): empty for a plain install
        /// (and for one `install --list` lists, which doesn't say); nil when a recorded value isn't safe to pass back.
        var options: [String]? = []

        /// Checked against crates.io and offered as an update: one install, from crates.io, with options BrewxPort
        /// can pass back.
        var isChecked: Bool { source == .cratesIO && copies == 1 && options != nil }
        /// One install from crates.io whose recorded options BrewxPort won't pass back (`unsafeOptions`): looked up,
        /// so a newer version shows as held back with the reason, never offered.
        var hasUnsafeOptions: Bool { source == .cratesIO && copies == 1 && options == nil }
    }

    /// `.crates2.json`, as much of it as BrewxPort uses: each install's key, executables and the options it was
    /// installed with. `version_req` isn't read: it doesn't hold an install back (a plain `cargo install ripgrep`
    /// moved `=14.1.0` to 16.0.0 in the captures).
    struct Record: Decodable {
        struct Install: Decodable {
            let bins: [String]?
            let features: [String]?
            let allFeatures: Bool?
            let noDefaultFeatures: Bool?
            let profile: String?
            let target: String?
            /// `rustc -vV` of the Rust that built it, whose `host:` line names the target a plain install gets.
            let rustc: String?

            enum CodingKeys: String, CodingKey {
                case bins, features, profile, target, rustc
                case allFeatures = "all_features"
                case noDefaultFeatures = "no_default_features"
            }
        }

        let installs: [String: Install]?
    }

    /// The options an upgrade passes so nothing the crate was installed with silently changes (ruling R11):
    /// `--features a,b`, `--all-features`, `--no-default-features`, `--profile p` (unless `release`), and `--target t`
    /// when it isn't the host of the Rust that built it (a plain install records that host; when the record doesn't
    /// name the host, the recorded target is passed). The values come from cargo's own file, and each must still be a
    /// plain name, none starting with `-`: a feature of letters, digits and `_+./-` (`dep/feature`), a profile of
    /// letters, digits, `_` and `-`. A recorded target must be one of the Mac's own (`macTargets`, ruling R12), even
    /// when it's the host and isn't passed. Nil when a value isn't.
    static func options(_ install: Record.Install) -> [String]? {
        var arguments: [String] = []
        let features = install.features ?? []
        if !features.isEmpty {
            guard features.allSatisfy({ isPlain($0, alsoAllowing: "+./-") }) else { return nil }
            arguments += ["--features", features.joined(separator: ",")]
        }
        if install.allFeatures == true { arguments.append("--all-features") }
        if install.noDefaultFeatures == true { arguments.append("--no-default-features") }
        if let profile = install.profile, profile != "release" {
            guard isPlain(profile, alsoAllowing: "-") else { return nil }
            arguments += ["--profile", profile]
        }
        if let target = install.target {
            guard macTargets.contains(target) else { return nil }
            if target != host(install.rustc) { arguments += ["--target", target] }
        }
        return arguments
    }

    /// The targets a recorded install may name: rustc's own macOS triples, exactly. rustc reads any other name it
    /// doesn't know as a target-spec file (`<name>.json` in RUST_TARGET_PATH, else the folder it runs in, or the name
    /// itself when it ends `.json`), and a spec can name a linker, so no other target is passed back to cargo.
    static let macTargets: Set<String> = [
        "aarch64-apple-darwin", "x86_64-apple-darwin", "arm64e-apple-darwin", "x86_64h-apple-darwin",
    ]

    /// The `host:` line of a recorded `rustc -vV`.
    static func host(_ rustc: String?) -> String? {
        rustc?.split(whereSeparator: \.isNewline).first { $0.hasPrefix("host: ") }
            .map { $0.dropFirst("host: ".count).trimmingCharacters(in: .whitespaces) }
    }

    /// An ASCII letter, digit or `_`, then those or the characters in `extra`.
    private static func isPlain(_ value: String, alsoAllowing extra: String) -> Bool {
        func isWord(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar) || scalar == "_")
        }
        guard let first = value.unicodeScalars.first, isWord(first) else { return false }
        return value.unicodeScalars.allSatisfy { isWord($0) || extra.unicodeScalars.contains($0) }
    }

    /// Why a crate with options `options(_:)` refused isn't updated.
    static func unsafeOptionsReason(_ name: String) -> String {
        "\(name) was installed with options BrewxPort won't pass back to cargo, so BrewxPort doesn't update it."
    }

    /// The crates in a `.crates2.json`, one per name, sorted. An empty file (cargo creates one) has none. Throws when
    /// it isn't a record BrewxPort can read.
    static func crates(record data: Data) throws -> [Crate] {
        if isBlank(data) { return [] }
        let record: Record
        do {
            record = try JSONDecoder().decode(Record.self, from: data)
        } catch {
            throw unreadableRecord
        }
        var found: [Crate] = []
        for (key, install) in (record.installs ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let crate = crate(key: key, bins: install.bins ?? [], options: options(install)) else {
                throw unreadableRecord
            }
            found.append(crate)
        }
        return merged(found)
    }

    private static let unreadableRecord = EngineError(engine: .cargo, message: "Couldn't read Cargo's record of "
                                                      + "installed crates.")

    /// A file of nothing but spaces, tabs and line breaks (cargo creates its record files empty).
    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
    }

    /// One record key, `name version (source)`: `ripgrep 14.1.0 (registry+https://…/crates.io-index)`. Nil for
    /// anything else. The source is read for its kind and dropped.
    static func crate(key: String, bins: [String], options: [String]? = []) -> Crate? {
        let parts = key.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].count > 2, parts[2].hasPrefix("("),
              parts[2].hasSuffix(")") else { return nil }
        let source = parts[2].dropFirst().dropLast()
        let kind: Source
        if cratesIOSources.contains(String(source)) {
            kind = .cratesIO
        } else if source.hasPrefix("registry+") || source.hasPrefix("sparse+") {
            kind = .otherRegistry
        } else {
            kind = .notRegistry
        }
        return Crate(name: String(parts[0]), version: String(parts[1]), source: kind, bins: bins, options: options)
    }

    /// The crates in `cargo install --list`'s output: a line `ripgrep v14.1.0:` per crate (` (source)` before the
    /// colon for one not from crates.io), then one indented line per executable. Throws for a line it doesn't know.
    static func crates(list output: String) throws -> [Crate] {
        let unreadable = EngineError(engine: .cargo, message: "Couldn't read cargo's list of installed crates.")
        var found: [Crate] = []
        for line in output.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            if line.first?.isWhitespace == true {
                guard let last = found.popLast() else { throw unreadable }
                let bin = line.trimmingCharacters(in: .whitespaces)
                found.append(Crate(name: last.name, version: last.version, source: last.source,
                                   bins: last.bins + [bin]))
                continue
            }
            guard line.hasSuffix(":") else { throw unreadable }
            let parts = line.dropLast().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty, parts[1].count > 1, parts[1].hasPrefix("v") else {
                throw unreadable
            }
            var source = Source.cratesIO
            if parts.count == 3 {
                guard parts[2].hasPrefix("("), parts[2].hasSuffix(")") else { throw unreadable }
                // cargo names another registry `registry `…``, and gives a git or path install's location.
                let text = parts[2].dropFirst()
                source = text.hasPrefix("registry") || text.hasPrefix("sparse+") ? .otherRegistry : .notRegistry
            }
            found.append(Crate(name: String(parts[0]), version: String(parts[1].dropFirst()), source: source, bins: []))
        }
        return merged(found)
    }

    /// One crate per name, sorted by name. A name installed more than once becomes one row: the highest version and
    /// its options, every executable, and the least checkable source (so it's from crates.io only when every copy is).
    static func merged(_ crates: [Crate]) -> [Crate] {
        Dictionary(grouping: crates, by: \.name).map { name, copies -> Crate in
            guard copies.count > 1 else { return copies[0] }
            let newest = copies.max {
                EcosystemVersion.compare($0.version, $1.version, scheme: .semver) == .orderedAscending
            }
            let source: Source = copies.contains { $0.source == .notRegistry } ? .notRegistry
                : copies.contains { $0.source == .otherRegistry } ? .otherRegistry : .cratesIO
            return Crate(name: name, version: newest?.version ?? copies[0].version, source: source,
                         bins: Array(Set(copies.flatMap(\.bins))).sorted(), copies: copies.count,
                         options: (newest ?? copies[0]).options)
        }.sorted { $0.name < $1.name }
    }

    /// The crates cargo's record in `root` lists, without running cargo. Nil when cargo has to be asked: the record
    /// won't open or decode, or there's only the record a cargo before 1.41 kept (`.crates.toml`). Neither file means
    /// nothing was ever installed.
    static func recorded(root: String, read: RecordReader) -> [Crate]? {
        do {
            if let data = try read(root + "/.crates2.json") { return try crates(record: data) }
            guard let older = try read(root + "/.crates.toml"), !isBlank(older) else { return [] }
            return nil
        } catch {
            return nil
        }
    }

    /// Every installed crate, each asked for.
    public func listInstalled() async throws -> [Package] {
        try await listCrates().map { crate in
            Package(id: ref(crate.name), displayName: crate.name, installedVersion: crate.version,
                    installedOnRequest: true)
        }
    }

    /// The record's crates, else `cargo install --list`'s. Kept for `info` and `command`.
    private func listCrates() async throws -> [Crate] {
        guard tool.executable != nil else {
            throw EngineError(engine: .cargo, message: "\(EngineID.cargo.displayName) isn't installed")
        }
        let crates: [Crate]
        if let recorded = Self.recorded(root: installRoot, read: readRecord) {
            crates = recorded
        } else {
            let result = try await tool.run(["install", "--list"])
            guard result.exitCode == 0 else { throw tool.failure("cargo install --list failed", result) }
            crates = try Self.crates(list: result.stdout)
        }
        state.listed(crates)
        return crates
    }

    // MARK: outdated

    /// `checkOutdated()`'s updates.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// Each checked crate, and each held for its options, looked up in crates.io's index, a few at a time, against the
    /// Rust beside cargo. A lookup that fails leaves that crate out, named in `unchecked` (R6); when every one fails,
    /// the check fails. A newer version needing a newer Rust, or of a crate with unsafe options, is held back.
    public func checkOutdated() async throws -> OutdatedReport {
        // The offers (R36) change only when a check ends: Updates keeps showing the last check's rows while this one
        // runs, and an upgrade asked for meanwhile passes the version its row showed. A check that fails leaves them,
        // but takes its rows off Updates, so nothing can ask for them.
        let checkStarted = pacing.now()
        let crates = try await listCrates()
        let names = Self.indexNames(crates)
        guard !names.isEmpty else {
            state.checked(needsNewerRust: [:], offers: [])
            return OutdatedReport(packages: [])
        }
        let rust = await rustVersion()
        let answers = try await concurrentMap(names, limit: Self.concurrentLookups) { name in
            do {
                return Result<[IndexVersion], any Error>.success(try await Self.versions(name, from: registry))
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        let check = try Self.updates(crates, index: answers, rust: rust)
        // R42: each offered crate's executables at the version installed, so an upgrade can keep a `--bin` subset.
        let installed = Dictionary(crates.filter { !$0.bins.isEmpty }.map { ($0.name, $0.version) }) { first, _ in first }
        // One at a time, `spacing` apart from the last lookup of any check, within the budget from the first lookup and
        // the check's own limit, whichever ends first (`APIPacing`).
        var bins: [String: (version: String, bins: [String])] = [:]
        var deadline: ContinuousClock.Instant?
        let checkEnds = checkStarted.advanced(by: pacing.checkLimit - APIPacing.handOver)
        for name in check.updates.map(\.id.name).sorted() {
            guard let version = installed[name] else { continue }
            let ends = deadline ?? min(pacing.now().advanced(by: pacing.budget), checkEnds)
            deadline = ends
            if let last = state.lastAPILookup {
                let wait = pacing.spacing - (pacing.now() - last)
                if wait > .zero {
                    guard pacing.now().advanced(by: wait) < ends else { break }
                    try await pacing.sleep(wait)
                }
            }
            let remaining = ends - pacing.now()
            guard remaining > .zero else { break }
            try Task.checkCancellation()
            let found = await Self.within(remaining) { await Self.binNames(name, version: version, from: registry) }
            state.apiLookedUp(at: pacing.now())
            if let found = found ?? nil { bins[name] = (version, found) }
            if found == nil { break }
        }
        // A lookup cut off by cancellation reads as one that failed (`within`, `binNames`): a cancelled check throws
        // here, as anywhere else, and leaves the last check's offers as they were.
        try Task.checkCancellation()
        state.checked(needsNewerRust: check.needsNewerRust, offers: check.updates, bins: bins)
        return OutdatedReport(packages: check.updates, unchecked: check.unchecked, held: check.held)
    }

    /// crates.io's answer for one version of a crate, as much as R42 reads: its executables.
    struct VersionAnswer: Decodable {
        struct Version: Decodable {
            let binNames: [String]?

            enum CodingKeys: String, CodingKey { case binNames = "bin_names" }
        }

        let version: Version
    }

    /// The executables crates.io lists for `name` at `version` (`/api/v1/crates/<name>/<version>`, `bin_names`); nil
    /// when the lookup or its answer fails, which leaves the upgrade plain.
    static func binNames(_ name: String, version: String, from registry: any RegistryFetching) async -> [String]? {
        guard PackageNameRules.isValid(name, for: .cargo), EcosystemVersion.isValid(version, scheme: .semver),
              let url = URL(string: "https://crates.io/api/v1/crates/\(name)/\(version)"),
              let data = try? await fetch(url, crate: name, from: registry, what: "crates.io") else { return nil }
        return binNames(versionAnswer: data)
    }

    /// `work`'s answer, or nil when it doesn't come within `limit` on the real clock (then it's cancelled).
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func binNames(versionAnswer data: Data) -> [String]? {
        (try? JSONDecoder().decode(VersionAnswer.self, from: data))?.version.binNames
    }

    /// R42: the executables an upgrade keeps with `--bin`: `recorded` (what the record names) when it's a strict
    /// subset of `all` (the version's own) and each is a plain name; nil otherwise, for a plain upgrade.
    static func keptBins(recorded: [String], all: [String]) -> [String]? {
        guard !recorded.isEmpty, recorded.allSatisfy({ isPlain($0, alsoAllowing: "-") }),
              Set(recorded).isStrictSubset(of: Set(all)) else { return nil }
        return recorded
    }

    /// The Rust beside cargo (`rustc --version` from cargo's own folder, so the same toolchain), as its release. Nil
    /// when it doesn't answer: then nothing is held back for it.
    private func rustVersion() async -> String? {
        guard let result = try? await tool.run(sibling: "rustc", ["--version"]), result.exitCode == 0,
              let version = Self.version(result.stdout, of: "rustc") else { return nil }
        return Self.release(version)
    }

    /// The index names to look up for `crates` (the checked ones and the ones held for their options, lowercased),
    /// each once, sorted.
    static func indexNames(_ crates: [Crate]) -> [String] {
        Set(crates.filter(isLookedUp).map { $0.name.lowercased() }
            .filter { PackageNameRules.isValid($0, for: .cargo) }).sorted()
    }

    /// Looked up in crates.io's index: a checked crate, or one held for its options.
    private static func isLookedUp(_ crate: Crate) -> Bool { crate.isChecked || crate.hasUnsafeOptions }

    /// Why a version is held back for its Rust: "Needs Rust 1.96".
    public static func needsRustReason(_ version: String) -> String { "Needs Rust \(version)" }

    /// A crate's file in crates.io's sparse index: its lowercased name under cargo's prefix folders (`1/a`, `2/ab`,
    /// `3/a/abc`, `ri/pg/ripgrep`). Nil for a name that isn't a crate name.
    static func indexURL(_ name: String) -> URL? {
        guard PackageNameRules.isValid(name, for: .cargo) else { return nil }
        let lower = name.lowercased()
        let characters = Array(lower)
        let prefix: String
        switch characters.count {
        case 1: prefix = "1"
        case 2: prefix = "2"
        case 3: prefix = "3/" + String(characters[0])
        default: prefix = String(characters[0..<2]) + "/" + String(characters[2..<4])
        }
        return URL(string: "https://index.crates.io/\(prefix)/\(lower)")
    }

    /// One version in an index file, as much of it as BrewxPort uses.
    struct IndexVersion: Decodable, Equatable, Sendable {
        let vers: String
        let yanked: Bool?
        /// The oldest Rust that builds it (`1.96`); nil when the crate doesn't say.
        let rustVersion: String?

        enum CodingKeys: String, CodingKey {
            case vers, yanked
            case rustVersion = "rust_version"
        }
    }

    /// The versions in one index file (a JSON object per line); a line that isn't one is skipped. Nil when none is.
    static func indexVersions(_ data: Data) -> [IndexVersion]? {
        let decoder = JSONDecoder()
        let versions = data.split(separator: 0x0A).compactMap { try? decoder.decode(IndexVersion.self, from: Data($0)) }
        return versions.isEmpty ? nil : versions
    }

    /// `name`'s versions in crates.io's index. No such crate (404), the index's other refusals, being offline and an
    /// answer that can't be read are `EngineError`s; anything else (a cancelled task, demo mode's uncaptured answer)
    /// is thrown as it is.
    static func versions(_ name: String, from registry: any RegistryFetching) async throws -> [IndexVersion] {
        guard let url = indexURL(name) else {
            throw EngineError(engine: .cargo, message: "Invalid package name: \(name)")
        }
        let data = try await fetch(url, crate: name, from: registry, what: "crates.io's index")
        guard let versions = indexVersions(data) else {
            throw EngineError(engine: .cargo, message: "Couldn't read crates.io's index for \(name)")
        }
        return versions
    }

    /// What an outdated check found: the updates, the crates held back (for their Rust, or their options), and the
    /// ones it couldn't look up.
    struct Check: Equatable {
        var updates: [Package] = []
        /// Crate name → the Rust its newest version needs, newer than the Rust beside cargo.
        var needsNewerRust: [String: String] = [:]
        /// Newer versions nobody may update to here: needing a newer Rust, or of a crate with unsafe options.
        var held: [HeldUpdate] = []
        var unchecked = UncheckedPackages.none
    }

    /// The updates the index's answers (keyed by lowercased name) give `crates`: each checked crate's newest version
    /// that isn't yanked, by semver, and not a pre-release for a stable install. When that version needs a newer
    /// Rust than `rust` (nil: not known, so not checked), it's held back instead, and so is one of a crate whose
    /// recorded options BrewxPort won't pass back. Throws when there was something to check and no answer came back.
    static func updates(_ crates: [Crate], index: [String: Result<[IndexVersion], any Error>], rust: String?) throws
        -> Check {
        var updates: [Package] = []
        var needsNewerRust: [String: String] = [:]
        var held: [HeldUpdate] = []
        let unchecked = try OutdatedLookups.tally(
            crates.filter(isLookedUp), answers: index, key: { $0.name.lowercased() }, name: \.name,
            noAnswer: { failure in
                failure.map { EngineError(engine: .cargo, message: "BrewxPort couldn't check crates.io for newer "
                                          + "versions: " + OutdatedLookups.describe($0)) }
            }
        ) { crate, versions in
            let candidates = versions.filter { $0.yanked != true }.map(\.vers)
            guard let newer = EcosystemVersion.newerVersion(than: crate.version, among: candidates, scheme: .semver)
            else { return }
            let row = Package(id: PackageRef(engine: .cargo, kind: .tool, name: crate.name), displayName: crate.name,
                              installedVersion: crate.version, latestVersion: newer)
            if crate.hasUnsafeOptions {
                held.append(HeldUpdate(package: row, hold: UpdateHold(reason: unsafeOptionsReason(crate.name),
                                                                      blocksAutomatic: true, blocksManual: true)))
                return
            }
            if let rust, let needs = versions.first(where: { $0.vers == newer })?.rustVersion,
               EcosystemVersion.isValid(needs, scheme: .semver),
               EcosystemVersion.compare(needs, rust, scheme: .semver) == .orderedDescending {
                needsNewerRust[crate.name] = needs
                held.append(HeldUpdate(package: row, hold: UpdateHold(reason: needsRustReason(needs),
                                                                      blocksAutomatic: true, blocksManual: true)))
                return
            }
            updates.append(row)
        }
        return Check(updates: updates.sorted { $0.id.name < $1.id.name }, needsNewerRust: needsNewerRust,
                     held: held.sorted { $0.package.id.name < $1.package.id.name }, unchecked: unchecked)
    }

    // MARK: search

    /// `cargo search`, which asks crates.io (or the registry cargo is set up for). A query cargo would read as an
    /// option (`--index …`) finds nothing, without asking. R43: each row's version is remembered, so its install
    /// installs that version.
    public func search(_ query: String) async throws -> [Package] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError(engine: .cargo, message: "Search query is empty") }
        guard !text.hasPrefix("-") else { return [] }
        let result = try await tool.run(Self.searchArguments + [text])
        guard result.exitCode == 0 else { throw tool.failure("cargo search failed", result) }
        let rows = Self.searchResults(result.stdout)
        state.searched(rows)
        return rows
    }

    /// The crates in `cargo search`'s output, in its order: `name = "version"    # description` (cut with `…` past a
    /// width). Other lines (`... and 827 crates more`) are skipped, and so are names cargo couldn't install by name.
    /// R43: a version that isn't semver isn't shown (its install is plain).
    static func searchResults(_ output: String) -> [Package] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let equals = line.range(of: " = \"") else { return nil }
            let name = String(line[..<equals.lowerBound])
            let rest = line[equals.upperBound...]
            guard PackageNameRules.isValid(name, for: .cargo), let quote = rest.firstIndex(of: "\"") else { return nil }
            let after = rest[rest.index(after: quote)...]
            var summary: String?
            if let hash = after.range(of: "# ") {
                guard after[..<hash.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
                summary = nonBlank(String(after[hash.upperBound...]))
            } else if !after.allSatisfy(\.isWhitespace) {
                return nil
            }
            let version = nonBlank(String(rest[..<quote])).flatMap {
                EcosystemVersion.isValid($0, scheme: .semver) ? $0 : nil
            }
            return Package(id: PackageRef(engine: .cargo, kind: .tool, name: name), displayName: name,
                           latestVersion: version, summary: summary)
        }
    }

    // MARK: info

    /// crates.io's API answer for one crate, as much of it as BrewxPort uses.
    struct CrateAnswer: Decodable {
        struct Crate: Decodable {
            let name: String?
            let description: String?
            let homepage: String?
            let repository: String?
            let maxStableVersion: String?
            let maxVersion: String?

            enum CodingKeys: String, CodingKey {
                case name, description, homepage, repository
                case maxStableVersion = "max_stable_version"
                case maxVersion = "max_version"
            }
        }

        struct Version: Decodable {
            let num: String
            let binNames: [String]?

            enum CodingKeys: String, CodingKey {
                case num
                case binNames = "bin_names"
            }
        }

        let crate: Crate
        let versions: [Version]?
    }

    /// The crate on crates.io: its description, home page (else repository, else its crates.io page), newest stable
    /// version and executables (an installed crate's own, else the newest version's). A crate installed from git, a
    /// folder or another registry isn't the one crates.io has under its name, so its details are its own record's.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .cargo, ref.kind == .tool else {
            throw EngineError(engine: .cargo, message: "Package belongs to a different engine")
        }
        try PackageNameRules.validate(ref.name, for: .cargo)
        let installed = state.crate(ref.name)
        if let installed, installed.source != .cratesIO {
            return PackageDetails(ref: ref, installedVersion: installed.version, executables: installed.bins)
        }
        guard let url = URL(string: "https://crates.io/api/v1/crates/\(ref.name)") else {
            throw EngineError(engine: .cargo, message: "Invalid package name: \(ref.name)")
        }
        let data = try await Self.fetch(url, crate: ref.name, from: registry, what: "crates.io")
        let answer: CrateAnswer
        do {
            answer = try JSONDecoder().decode(CrateAnswer.self, from: data)
        } catch {
            throw EngineError(engine: .cargo, message: "Couldn't read crates.io's answer for \(ref.name)")
        }
        guard let latest = nonBlank(answer.crate.maxStableVersion) ?? nonBlank(answer.crate.maxVersion) else {
            throw EngineError(engine: .cargo, message: "crates.io had no information for \(ref.name)")
        }
        let summary = answer.crate.description.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let homepage = webURL(answer.crate.homepage) ?? webURL(answer.crate.repository)
            ?? URL(string: "https://crates.io/crates/\(ref.name)")
        let executables = installed?.bins ?? answer.versions?.first { $0.num == latest }?.binNames
        return PackageDetails(ref: ref, summary: nonBlank(summary), homepage: homepage, latestVersion: latest,
                              reportedName: nonBlank(answer.crate.name), executables: executables)
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// One crate per install and upgrade: an upgrade passes the options cargo recorded for its crate, and one
    /// command's options would apply to every crate in it; a step per crate also gives each build its own result.
    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? {
        operation == .install || operation == .upgrade ? 1 : nil
    }

    /// `install` with a crate name (an upgrade too: cargo replaces the older version, and gets the options the crate
    /// was installed with, `upgradable`, and the version the check offered, `offeredVersion`) and `uninstall` with
    /// crate names. An upgrade of a crate not installed from crates.io is refused: `cargo install` would swap it for
    /// crates.io's crate of that name. R43: an install from Discover passes the version its row showed, from `cargo
    /// search`'s own output (`--version =<it>`, as R36 does for an upgrade); a crate no search showed with a version
    /// installs plain: cargo's newest stable version.
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard !refs.isEmpty else { throw EngineError(engine: .cargo, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .cargo && $0.kind == .tool }) else {
            throw EngineError(engine: .cargo, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .cargo, message: "Cargo installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .cargo, message: "Cargo has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .cargo, message: "Cargo commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .cargo)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .cargo) }
        try requireTargetLimit(refs, for: op)
        let names = refs.map(\.name)
        switch op {
        case .install:
            guard let shown = state.searchedVersion(names[0]) else { return try tool.command(["install"] + names) }
            try requireNewer(names[0], than: shown)
            return try tool.command(["install", "--version", "=" + shown] + names)
        case .upgrade:
            let crate = try upgradable(names[0])
            let version = try offeredVersion(names[0])
            try requireNewer(names[0], than: version, installed: crate)
            let bins = state.bins(names[0]).flatMap { found in
                found.version == crate.version ? Self.keptBins(recorded: crate.bins, all: found.bins) : nil
            } ?? []
            return try tool.command(["install"] + (crate.options ?? []) + bins.flatMap { ["--bin", $0] }
                                    + ["--version", "=" + version] + names)
        case .remove: return try tool.command(["uninstall"] + names)
        case .repair:
            throw EngineError(engine: .cargo, message: "Cargo repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .cargo, message: "Cargo can't mark packages")
        }
    }

    /// R42: `--version =X` installs X over anything, newer or not (`t13-install-tokei-prerelease-down`), so before an
    /// upgrade or a Discover install (R43) passes it, what's installed now (`installed`, else cargo's record read again,
    /// else the last listing) must be older; refused in one line otherwise. Nothing installed: nothing to protect.
    private func requireNewer(_ name: String, than version: String, installed: Crate? = nil) throws {
        let current = installed ?? (Self.recorded(root: installRoot, read: readRecord)?.first { $0.name == name }
            ?? state.listedCrates[name])
        guard let current, EcosystemVersion.compare(current.version, version, scheme: .semver) != .orderedAscending
        else { return }
        throw EngineError(engine: .cargo, message: "\(name) is already at \(current.version), so BrewxPort doesn't "
                          + "install \(version) over it.")
    }

    /// R36: the version the last outdated check offered `name`, from crates.io's index and a semver version, which an
    /// upgrade passes as `--version =<it>`, so cargo installs exactly what Updates showed. Plain `cargo install` takes
    /// the newest stable version, which for a pre-release install can be older than what's installed. Refused when that
    /// check offered none: never from the person's text, and never a plain upgrade.
    private func offeredVersion(_ name: String) throws -> String {
        guard let version = state.offer(name), EcosystemVersion.isValid(version, scheme: .semver) else {
            throw EngineError(engine: .cargo, message: "BrewxPort hasn't found a newer version of \(name) on "
                              + "crates.io, so it doesn't update it.")
        }
        return version
    }

    /// The crate an upgrade of `name` starts from, with the options it passes again. Cargo's record is read again
    /// here (it's a small local file), so the command follows what's installed now; when only cargo can say
    /// (`recorded` is nil), the last listing does. Refused, each with a one-line reason: a crate that isn't installed,
    /// one installed more than once, one not from crates.io, and one whose recorded options aren't safe to pass back.
    private func upgradable(_ name: String) throws -> Crate {
        let installed: [String: Crate]
        if let recorded = Self.recorded(root: installRoot, read: readRecord) {
            installed = Dictionary(recorded.map { ($0.name, $0) }) { first, _ in first }
        } else {
            installed = state.listedCrates
        }
        guard let crate = installed[name] else {
            throw EngineError(engine: .cargo, message: "BrewxPort can't find \(name) among Cargo's installed "
                              + "crates, so it doesn't update it.")
        }
        guard crate.copies == 1 else {
            throw EngineError(engine: .cargo,
                              message: "\(name) is installed more than once, so BrewxPort doesn't update it.")
        }
        guard crate.source == .cratesIO else {
            throw EngineError(engine: .cargo,
                              message: "\(name) wasn't installed from crates.io, so BrewxPort doesn't update it.")
        }
        guard crate.options != nil else {
            throw EngineError(engine: .cargo, message: Self.unsafeOptionsReason(name))
        }
        return crate
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .cargo, kind: .tool, name: name) }

    /// One GET to crates.io (`what` names which part, for messages). 404 means no such crate; crates.io's other
    /// refusals and being offline are `EngineError`s; anything else (a cancelled task, demo mode's uncaptured answer)
    /// is thrown as it is.
    private static func fetch(_ url: URL, crate name: String, from registry: any RegistryFetching, what: String)
        async throws -> Data {
        do {
            return try await registry.get(url)
        } catch RegistryFetchError.status(404) {
            throw EngineError(engine: .cargo, message: "crates.io has no crate named \(name)")
        } catch let error as RegistryFetchError {
            throw EngineError(engine: .cargo, message: "\(what) didn't answer for \(name): \(error)")
        } catch let error as URLError where error.code != .cancelled {
            throw EngineError(engine: .cargo, message: "Couldn't reach crates.io: \(error.localizedDescription)")
        }
    }

    /// What the last `detect()`, list and outdated check found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedRoot: URL?
        private var crates: [String: Crate] = [:]
        private var heldForRust: [String: String] = [:]
        private var heldForOptions: [String: String] = [:]

        var root: URL? { lock.withLock { detectedRoot } }
        var needsNewerRust: [String: String] { lock.withLock { heldForRust } }
        var unsafeOptions: [String: String] { lock.withLock { heldForOptions } }

        func detected(root: URL?) { lock.withLock { detectedRoot = root } }

        func listed(_ found: [Crate]) {
            let map = Dictionary(found.map { ($0.name, $0) }) { first, _ in first }
            let unsafe = Dictionary(found.filter { $0.source == .cratesIO && $0.copies == 1 && $0.options == nil }
                .map { ($0.name, CargoEngine.unsafeOptionsReason($0.name)) }) { first, _ in first }
            lock.withLock {
                crates = map
                heldForOptions = unsafe
            }
        }

        /// After an outdated check: the crates held for their Rust, the version it offered each update (R36), and the
        /// executables crates.io lists for each offered crate's installed version (R42).
        func checked(needsNewerRust names: [String: String], offers updates: [Package],
                     bins: [String: (version: String, bins: [String])] = [:]) {
            let versions = Dictionary(updates.compactMap { row in row.latestVersion.map { (row.id.name, $0) } }) {
                first, _ in first
            }
            lock.withLock {
                heldForRust = names
                offered = versions
                versionBins = bins
            }
        }

        /// The executables crates.io lists for `name` at the version the last check saw installed (R42).
        func bins(_ name: String) -> (version: String, bins: [String])? { lock.withLock { versionBins[name] } }

        /// When the last crates.io API lookup ended (`APIPacing.spacing`), on the pacing's clock.
        var lastAPILookup: ContinuousClock.Instant? { lock.withLock { lastLookup } }
        private var lastLookup: ContinuousClock.Instant?

        func apiLookedUp(at instant: ContinuousClock.Instant) { lock.withLock { lastLookup = instant } }
        private var versionBins: [String: (version: String, bins: [String])] = [:]

        /// The version the last outdated check offered `name`, from crates.io's index; nil when it offered none.
        func offer(_ name: String) -> String? { lock.withLock { offered[name] } }

        /// R43: the versions Discover's rows showed, from `cargo search`, by crate; each search's rows replace their
        /// names' earlier ones, and a row without a version forgets its name's.
        func searched(_ rows: [Package]) {
            lock.withLock {
                for row in rows { shown[row.id.name] = row.latestVersion }
            }
        }

        func searchedVersion(_ name: String) -> String? { lock.withLock { shown[name] } }
        private var shown: [String: String] = [:]
        private var offered: [String: String] = [:]

        func crate(_ name: String) -> Crate? { lock.withLock { crates[name] } }

        /// The last listing's crates, by name.
        var listedCrates: [String: Crate] { lock.withLock { crates } }
    }
}

// MARK: Task 10: commands

extension CargoEngine: ExecutableNaming {
    /// The crate's executables as the last listing recorded them (ripgrep's `rg`); nil for a crate it didn't show.
    public func executables(of name: String) -> [String]? {
        state.crate(name)?.bins
    }
}
