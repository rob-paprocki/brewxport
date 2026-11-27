import Foundation

/// RubyGems' command-line tools: the gems with executables that `gem install` puts in a Ruby's gem folder, driven
/// through `gem`. Always as the user, never as root (Plan 9). Found from the login shell's PATH first, then the fixed
/// folders (`fixedFolders`).
///
/// - Each Ruby has its own gems. The `gem` used is the one the user's shell runs (a version manager's shim, Homebrew's,
///   Apple's), and `detect()` reads `gem environment` for which Ruby that is (`rubySource`), where it installs
///   (`installLocation`) and where executables go (`binLocation`). Apple's Ruby (`.system`) keeps its gems where only
///   root can write; BrewxPort never runs gem as root (Task 10 turns its actions off).
/// - Installed: `gem list --local`, but only gems with executables and only the copies the user installed, as a fixed
///   Ruby script run by the `ruby` beside gem says (`executablesScript`, `tools`). Libraries aren't tools, and nor are
///   the gems that come with Ruby (R18): its default gems, and its bundled gems (irb, rake, rbs, rdoc, typeprof…) at
///   the version it put in its own gem folder. A newer copy the user installed is a tool. Ruby has no complete list of its
///   bundled gems once installed, so its own gem folder (RubyGems' original default, from RbConfig) decides; when gem
///   installs into that same folder (rbenv, asdf, mise, chruby), its bundled gems can't be told apart and are listed,
///   and the ones with executables are marked `shippedWithRuby` (R19): never removed, never updated automatically.
/// - Outdated: `gem outdated` names the candidates, and each is looked up in RubyGems.org's compact index
///   (`indexURL`): the newest version this Ruby and RubyGems meet the requirements of, for the `ruby` platform or this
///   Mac's own, is offered. `gem outdated` checks neither, and prints nothing (exit 0) when it can't reach its source,
///   so when it names no tool every tool is looked up, and when no lookup answers the check fails instead of saying
///   "up to date".
/// - Discover runs `gem search --remote`; details come from RubyGems.org's API.
/// - Install and update always pass `--remote`, so a `*.gem` file in the working folder is never installed instead
///   (R16), and `--no-document`. Uninstall removes every version and its executables, never one a dependent needs,
///   and is confirmed afterwards (`confirmationScript`): gem exits 0 when it removed nothing (a default gem, a gem in
///   another of its folders), so the step fails while a non-default copy is still there.
public struct GemEngine: Engine, InstallLocationReporting {
    public let id: EngineID = .gem
    /// gem prints text; the index and the API are read directly.
    public let capabilities: EngineCapabilities = []

    /// Which Ruby `gem` belongs to, from where its Ruby (and gem itself) is.
    public enum RubySource: String, Sendable, Equatable {
        case homebrew, macports, rbenv, asdf, mise
        /// chruby's and ruby-install's rubies (`~/.rubies`, `/opt/rubies`).
        case chruby
        /// Apple's Ruby in `/usr/bin`: its gem folder belongs to root, so nothing can be installed into it as the user.
        case system
        case other
    }

    /// Ruby's own gem folder, where `make install` put its bundled gems: RubyGems' original `Gem.default_dir`, from
    /// RbConfig (Homebrew's and Apple's Ruby point `Gem.default_dir` elsewhere), and whether gem installs there too.
    /// Then `linked`, R38: whether a copy's gemspec is a link that resolves outside the folder it sits in. Homebrew's
    /// Ruby links each bundled gemspec from the Cellar into the gem folder it installs into
    /// (`Fixtures/gem/t13-executables-script.txt` shows every one of them twice), so that copy is Ruby's own, wherever
    /// the link is and whichever Ruby's keg it points into (an older one's, left behind, too). `gem install` writes a
    /// regular file. A link that can't be resolved isn't Ruby's.
    private static let ownFolder = "own = File.expand_path(File.join(RbConfig::CONFIG[\"rubylibprefix\"].to_s, "
        + "\"gems\", RbConfig::CONFIG[\"ruby_version\"].to_s)); shared = own == File.expand_path(Gem.dir); "
        + "linked = lambda { |spec| file = spec.loaded_from.to_s; !file.empty? && File.symlink?(file) && "
        + "((File.dirname(File.realpath(file)) != File.realpath(File.dirname(file))) rescue false) }; "

    /// Prints `ruby-gems-separate` or `ruby-gems-shared` (whether gem installs into Ruby's own gem folder), then
    /// `name (version) place` for every installed copy of each gem whose newest version has executables, where place
    /// is `default` (a default gem), `ruby` (in Ruby's own gem folder, or a gemspec linked from elsewhere, R38) or
    /// `user` (anywhere else, a regular file). Fixed text, for Ruby 2.6 and later: nothing BrewxPort is given goes
    /// into it.
    public static let executablesScript = ownFolder
        + "puts(shared ? \"ruby-gems-shared\" : \"ruby-gems-separate\"); "
        + "Gem::Specification.latest_specs(true).each { |stub| latest = stub.to_spec; "
        + "next if latest.nil? || latest.executables.empty?; "
        + "(Gem::Specification.find_all_by_name(latest.name) || []).each { |spec| next if spec.nil?; "
        + "place = spec.default_gem? ? \"default\" : "
        + "((File.expand_path(spec.base_dir) == own || linked.call(spec)) ? \"ruby\" : \"user\"); "
        + "puts \"#{spec.name} (#{spec.version}) #{place}\" } }"

    /// Exits 0 when none of the gems named after `--` has a copy left that isn't Ruby's own (a default gem, a gemspec
    /// linked from elsewhere (R38), or in Ruby's own folder when gem installs elsewhere: `tools`' rule), else
    /// names each on stderr and exits 1. A gemspec Ruby can't load counts as left. Fixed text: the names are arguments,
    /// never part of the script.
    public static let confirmationScript = ownFolder
        + "left = ARGV.select { |name| (Gem::Specification.find_all_by_name(name) || []).any? { |spec| spec.nil? || "
        + "(!spec.default_gem? && !linked.call(spec) && (shared || File.expand_path(spec.base_dir) != own)) } }; "
        + "left.each { |name| warn \"#{name} is still installed.\" }; exit(left.empty? ? 0 : 1)"

    /// The gems Ruby bundles that install executables (R19), from Ruby's own `gems/bundled_gems`: in 3.3 and 3.4,
    /// debug (`rdbg`), racc, rake, rbs and typeprof; 4.0 adds irb and rdoc (`rdoc`, `ri`), which were default gems
    /// before (https://github.com/ruby/ruby/blob/v4.0.0/gems/bundled_gems, and the v3_3_0 and v3_4_0 tags). R38: 4.0's
    /// file also lists minitest and test-unit (bundled since 2.2), and in Ruby 4.0 both have executables: the captured
    /// Homebrew Ruby 4.0.10's executables script names all nine with a copy in Ruby's own gem folder
    /// (`Fixtures/gem/t13-executables-script.txt`). Used only when gem installs into Ruby's own gem folder, where Ruby's
    /// copies can't be told from the user's: such a gem is still a tool, marked `shippedWithRuby`.
    public static let bundledWithExecutables: Set<String> = ["debug", "irb", "minitest", "racc", "rake", "rbs", "rdoc",
                                                             "test-unit", "typeprof"]

    /// Not for the app: the gems with executables among the captured Homebrew Ruby's (`Fixtures/gem`), as its real
    /// executables script answer names them (`t13-executables-script.txt`): Ruby's bundled ones, its default gems
    /// bundler (`bundle`, `bundler`), erb and syntax_suggest, and the two the capture installed, lolcat and thor. Demo
    /// mode and the tests make the script's answer from them for listings whose answer wasn't captured.
    public static let capturedGemsWithExecutables: Set<String> = bundledWithExecutables
        .union(["bundler", "erb", "lolcat", "syntax_suggest", "thor"])

    static let listArguments = ["list", "--local"]
    static let environmentArguments = ["environment"]
    static let outdatedArguments = ["outdated"]
    static let searchArguments = ["search", "--remote"]
    static let uninstallArguments = ["uninstall", "--all", "--executables", "--abort-on-dependent"]
    /// From gem's sources only (R16), without documentation.
    static let installArguments = ["install", "--remote", "--no-document"]
    /// Index lookups at a time, for an outdated check.
    static let concurrentLookups = 4
    /// The most search results kept.
    static let searchLimit = 50

    private let tool: LanguageTool
    private let registry: any RegistryFetching
    private let home: String
    private let state = State()
    private let access: InstallAccessState

    public var executableURL: URL? { tool.executable }

    /// Why this account can't change RubyGems' tools: macOS's own Ruby and MacPorts' Ruby keep their gems where only an
    /// administrator can write (`readOnlyReason(for:)`), and any other Ruby's gem folder or executables folder the
    /// last detect found not writable.
    public var readOnlyReason: String? { access.readOnlyReason }

    /// The line for a Ruby whose gems only an administrator can change, with the fix; nil for any other.
    static func readOnlyReason(for source: RubySource?) -> String? {
        switch source {
        case .system?:
            return "This is macOS's own Ruby, and only an administrator can change its gems. Set up Homebrew's Ruby "
                + "to manage gems with BrewxPort."
        case .macports?:
            return "MacPorts' Ruby keeps its gems in /opt/local, which only an administrator can change. Set up "
                + "Homebrew's Ruby to manage gems with BrewxPort."
        default:
            return nil
        }
    }

    /// The gem folder (`Gem.dir`) as the last `detect()` read it from `gem environment`: where `gem install` puts gems.
    public var installLocation: URL? {
        state.environment?.installDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Where gem puts executables, as the last `detect()` read it from `gem environment`.
    public var binLocation: URL? {
        state.environment?.executableDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Which Ruby the last `detect()` found gem belongs to; nil before one, or when gem didn't answer.
    public var rubySource: RubySource? { state.source }

    /// That Ruby's version (`4.0.10`), from `gem environment`.
    public var rubyVersion: String? { state.environment?.rubyVersion }

    /// The tools the last outdated check couldn't look up (R6): name → a one-line reason. They aren't in Updates.
    public var couldntCheck: [String: String] { state.unchecked }

    /// The tools the last outdated check found RubyGems.org doesn't have (its compact index answered 404): a private
    /// gem server's, or one built on this Mac. They can't be checked there, so they're never offered, and never count
    /// as a failed or partial check. Sorted.
    public var notOnRubyGems: [String] { state.notListed }

    /// Whether gem installs into Ruby's own gem folder (rbenv, asdf, mise, chruby), as the last listing found; nil
    /// before one. Then only default gems can be told from the user's, and `shippedWithRuby` names the rest of Ruby's.
    public var sharesRubysGemFolder: Bool? { state.separate.map { !$0 } }

    /// The listed tools that came with Ruby (R19): in a gem folder Ruby shares, the bundled gems with executables.
    /// They can be updated by hand, but never by an automatic update (`checkOutdated` holds their updates back from
    /// those, `shippedWithRubyHold`), and removing one is refused, since it would remove Ruby's own copy.
    public var shippedWithRuby: Set<String> { state.shipped }

    /// R19: an update of a gem that came with Ruby is the person's to make, never an automatic one.
    public static let shippedWithRubyHold = UpdateHold(
        reason: "Came with Ruby, so BrewxPort updates it only when you ask.", blocksAutomatic: true, blocksManual: false)

    /// The app's gem: the first on the login shell's PATH, then in `fixedFolders` (tests replace them). `registry`
    /// reads RubyGems.org; `base` is the environment every command starts from.
    public init(runner: CommandRunning, registry: any RegistryFetching, loginShell: @escaping LoginShellContextProvider,
                arch: Arch = .current, base: [String: String] = ProcessRunner.baseEnvironment,
                fixedFolders: (@Sendable (_ captured: [String: String]) -> [String])? = nil,
                isWritable: @escaping @Sendable (String) -> Bool = InstallAccess.isWritable) {
        let home = LanguageTool.home(base)
        let folders: @Sendable ([String: String]) -> [String] = fixedFolders ?? { captured in
            Self.fixedFolders(arch: arch, home: home, captured: captured)
        }
        tool = LanguageTool(engine: .gem, name: "gem", runner: runner, base: base, loginShell: loginShell,
                            fixedFolders: folders)
        self.registry = registry
        self.home = home
        access = InstallAccessState(isWritable: isWritable)
    }

    /// gem at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed. Its
    /// folders count as writable unless `isWritable` says otherwise; macOS's and MacPorts' Ruby never are.
    public init(runner: CommandRunning, registry: any RegistryFetching, executable: URL?,
                captured: [String: String] = [:], base: [String: String] = ProcessRunner.baseEnvironment,
                isWritable: @escaping @Sendable (String) -> Bool = { _ in true }) {
        tool = LanguageTool(engine: .gem, name: "gem", runner: runner, executable: executable, captured: captured,
                            base: base)
        self.registry = registry
        home = LanguageTool.home(base)
        access = InstallAccessState(isWritable: isWritable)
    }

    // MARK: finding gem

    /// Where gem is looked for after the login shell's PATH: Homebrew's bin folders (this Mac's own prefix first) and
    /// its keg-only `ruby`'s, MacPorts', the version managers' shims (rbenv, asdf, mise), then Apple's Ruby.
    static func fixedFolders(arch: Arch, home: String, captured: [String: String]) -> [String] {
        // Built in typed parts: one long chained expression is too slow for the CI compiler to type-check.
        let prefixes: [String] = arch == .arm64 ? ["/opt/homebrew", "/usr/local"] : ["/usr/local", "/opt/homebrew"]
        var folders: [String] = prefixes.map { $0 + "/bin" }
        folders += prefixes.map { $0 + "/opt/ruby/bin" }
        folders.append("/opt/local/bin")
        folders += [home + "/.rbenv/shims", home + "/.asdf/shims", home + "/.local/share/mise/shims", "/usr/bin"]
        return folders
    }

    // MARK: detect

    /// RubyGems' version, then `gem environment` for the folders and the Ruby. An environment gem doesn't give leaves
    /// RubyGems present without them; which Ruby it is then follows from gem's own path.
    public func detect() async -> EngineStatus {
        let status = await tool.detect(["--version"]) { Self.version($0) }
        var version: String?
        var environment: Environment?
        var source: RubySource?
        if case .present(let path, let found) = status {
            version = found
            if let result = try? await tool.run(Self.environmentArguments), result.exitCode == 0 {
                environment = Self.environment(result.stdout)
            }
            source = Self.rubySource(gem: path.path, ruby: environment?.rubyExecutable, home: home)
        }
        state.detected(version: version, environment: environment, source: source)
        if let reason = Self.readOnlyReason(for: source) {
            access.readOnly(reason)
        } else {
            access.checked(.gem, folders: [installLocation, binLocation].compactMap { $0 }, home: home)
        }
        return status
    }

    /// `gem --version`'s first line, `4.1.0`, when it's a gem version (Apple's RubyGems has four parts).
    static func version(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first else { return nil }
        let version = line.trimmingCharacters(in: .whitespaces)
        return EcosystemVersion.isValid(version, scheme: .gem) ? version : nil
    }

    /// What `gem environment` says about the Ruby and RubyGems that gem runs, as much as BrewxPort uses.
    struct Environment: Equatable, Sendable {
        var rubyGemsVersion: String?
        /// `4.0.10`, without the release date and platform.
        var rubyVersion: String?
        var installDirectory: String?
        var executableDirectory: String?
        var rubyExecutable: String?
        /// RubyGems' platforms for this Ruby: `ruby`, then the Mac's own (`arm64-darwin-24`).
        var platforms: [String] = []
    }

    /// `gem environment`'s `  - NAME: value` lines, and the `     - value` lines under `RUBYGEMS PLATFORMS:`. Nil when
    /// none of the lines BrewxPort reads is there. Only absolute paths are kept as folders.
    static func environment(_ output: String) -> Environment? {
        var environment = Environment()
        var found = false
        var inPlatforms = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("     - ") {
                let value = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                if inPlatforms, !value.isEmpty { environment.platforms.append(value) }
                continue
            }
            inPlatforms = false
            guard line.hasPrefix("  - "), let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.index(line.startIndex, offsetBy: 4)..<colon]
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            func path() -> String? { value.hasPrefix("/") ? value : nil }
            switch name {
            case "RUBYGEMS VERSION": environment.rubyGemsVersion = nonBlank(value)
            case "RUBY VERSION": environment.rubyVersion = value.split(separator: " ").first.map(String.init)
            case "INSTALLATION DIRECTORY": environment.installDirectory = path()
            case "EXECUTABLE DIRECTORY": environment.executableDirectory = path()
            case "RUBY EXECUTABLE": environment.rubyExecutable = path()
            case "RUBYGEMS PLATFORMS": inPlatforms = true
            default: continue
            }
            found = true
        }
        return found ? environment : nil
    }

    /// Which Ruby a `gem` at `path` belongs to, from that path alone (`/usr/bin/gem` is macOS's own, `/opt/local/…`
    /// MacPorts'); nil when the path doesn't say. The app offers Homebrew's Ruby beside macOS's and MacPorts' (R30).
    public static func rubySource(gemPath path: String, home: String = NSHomeDirectory()) -> RubySource? {
        source(of: path, home: home)
    }

    /// Which Ruby: its own path decides when gem gave one (an rbenv shim runs rbenv's Ruby), else gem's path.
    static func rubySource(gem: String, ruby: String?, home: String) -> RubySource {
        for path in [ruby, gem].compactMap({ $0 }) where path.hasPrefix("/") {
            if let source = source(of: path, home: home) { return source }
        }
        return .other
    }

    private static func source(of path: String, home: String) -> RubySource? {
        if path.contains("/.rbenv/") { return .rbenv }
        if path.contains("/.asdf/") { return .asdf }
        if path.contains("/mise/installs/") || path.contains("/mise/shims/") { return .mise }
        if path.hasPrefix(home + "/.rubies/") || path.hasPrefix("/opt/rubies/") { return .chruby }
        if ["/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/opt/", "/usr/local/Homebrew/"]
            .contains(where: path.hasPrefix) { return .homebrew }
        if path.hasPrefix("/opt/local/") { return .macports }
        if path == "/usr/bin/gem" || path == "/usr/bin/ruby"
            || path.hasPrefix("/System/Library/Frameworks/Ruby.framework/") { return .system }
        return nil
    }

    // MARK: installed

    /// One tool gem.
    struct Gem: Equatable, Sendable {
        let name: String
        /// The newest version the user installed: what Installed and Updates show.
        let version: String
        /// The highest version installed, of any kind (Ruby's own copies too): what `gem update` updates from, so what
        /// an update is compared with.
        let highest: String
        /// A bundled gem with executables in a gem folder Ruby shares (R19).
        let shippedWithRuby: Bool

        init(name: String, version: String, highest: String? = nil, shippedWithRuby: Bool = false) {
            self.name = name
            self.version = version
            self.highest = highest ?? version
            self.shippedWithRuby = shippedWithRuby
        }
    }

    /// One gem as `gem list --local` shows it: every installed version, newest first.
    struct Listed: Equatable, Sendable {
        let name: String
        let versions: [String]
    }

    /// The gems in `gem list --local`'s output: `name (versions)`, newest first, each maybe after `default: ` and
    /// before its platforms (`thor (1.5.0, 1.3.2)`, `bundler (4.1.1, default: 4.1.0)`, `nokogiri (1.19.7
    /// arm64-darwin)`). Blank lines and a terminal's `*** LOCAL GEMS ***` header are skipped; a name gem couldn't
    /// install by name is left out; any other line means the output isn't one BrewxPort knows, which is a failure
    /// rather than a short list. The message never repeats the line.
    static func listed(_ output: String) throws -> [Listed] {
        try output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("***") { return nil }
            guard let found = entry(text) else { throw unreadableList }
            let versions = try found.inside.split(separator: ",").map { part in
                var entry = part.trimmingCharacters(in: .whitespaces)
                if entry.hasPrefix("default: ") { entry = String(entry.dropFirst("default: ".count)) }
                guard let version = entry.split(separator: " ").first.map(String.init),
                      EcosystemVersion.isValid(version, scheme: .gem) else { throw unreadableList }
                return version
            }
            guard PackageNameRules.isValid(found.name, for: .gem) else { return nil }
            return Listed(name: found.name, versions: versions)
        }
    }

    /// Where one installed copy of a gem is, as the executables script says.
    enum Place: String, Sendable {
        /// One of Ruby's default gems.
        case `default`
        /// In Ruby's own gem folder: a gem Ruby bundled, unless gem installs there too.
        case ruby
        /// Anywhere else: installed by the user.
        case user
    }

    /// One installed copy of a gem with executables.
    struct Copy: Equatable, Sendable {
        let name: String
        let version: String
        let place: Place
    }

    /// The executables script's answer: whether gem installs outside Ruby's own gem folder, and every copy of each gem
    /// whose newest version has executables.
    struct Executables: Equatable, Sendable {
        let separate: Bool
        let copies: [Copy]
    }

    /// `executablesScript`'s output: `ruby-gems-separate` or `ruby-gems-shared`, then `name (version) place` lines.
    /// Anything else is a failure that doesn't repeat the line.
    static func executables(_ output: String) throws -> Executables {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let header = lines.first, ["ruby-gems-separate", "ruby-gems-shared"].contains(header) else {
            throw unreadableExecutables
        }
        let copies = try lines.dropFirst().compactMap { line -> Copy? in
            guard let space = line.lastIndex(of: " "),
                  let place = Place(rawValue: String(line[line.index(after: space)...])),
                  let found = entry(String(line[..<space])),
                  EcosystemVersion.isValid(found.inside, scheme: .gem) else { throw unreadableExecutables }
            guard PackageNameRules.isValid(found.name, for: .gem) else { return nil }
            return Copy(name: found.name, version: found.inside, place: place)
        }
        return Executables(separate: header == "ruby-gems-separate", copies: copies)
    }

    private static var unreadableExecutables: EngineError {
        EngineError(engine: .gem, message: "Couldn't read Ruby's answer about which gems have commands.")
    }

    /// `name (inside)` split into the name and what's inside the brackets; nil for any other line.
    private static func entry(_ line: String) -> (name: String, inside: String)? {
        guard line.hasSuffix(")"), let open = line.range(of: " (") else { return nil }
        let name = String(line[..<open.lowerBound])
        let inside = String(line[open.upperBound..<line.index(before: line.endIndex)])
        guard !name.isEmpty, !name.contains(" "), !inside.isEmpty else { return nil }
        return (name, inside)
    }

    private static var unreadableList: EngineError {
        EngineError(engine: .gem,
                    message: "Couldn't read RubyGems' list of gems: it has a line BrewxPort doesn't know.")
    }

    /// The tools among `listed` (R18): gems with executables that have a copy the user installed, each at the newest
    /// such version, with the highest version of any kind beside it. A default gem's copy is Ruby's, and so is one in
    /// Ruby's own gem folder when gem installs elsewhere (a bundled gem at the version Ruby shipped). When gem installs
    /// into Ruby's own folder too, only default gems can be told apart, so Ruby's bundled gems with executables
    /// (`bundledWithExecutables`) are listed but marked `shippedWithRuby` (R19).
    static func tools(_ listed: [Listed], executables: Executables) -> [Gem] {
        var users: [String: Set<String>] = [:]
        for copy in executables.copies {
            let rubys = copy.place == .default || (copy.place == .ruby && executables.separate)
            if !rubys { users[copy.name, default: []].insert(copy.version) }
        }
        return listed.compactMap { gem in
            guard let mine = users[gem.name], let newest = gem.versions.first(where: mine.contains) else { return nil }
            let highest = gem.versions.max { EcosystemVersion.compare($0, $1, scheme: .gem) == .orderedAscending }
            return Gem(name: gem.name, version: newest, highest: highest,
                       shippedWithRuby: !executables.separate && bundledWithExecutables.contains(gem.name))
        }.sorted { $0.name < $1.name }
    }

    /// Every tool gem, each asked for.
    public func listInstalled() async throws -> [Package] {
        try await listTools().map { gem in
            Package(id: ref(gem.name), displayName: gem.name, installedVersion: gem.version, installedOnRequest: true)
        }
    }

    /// `gem list --local`'s tools, by the executables script beside gem. Remembered for `info` and `command(for:)`.
    private func listTools() async throws -> [Gem] {
        let list = try await tool.run(Self.listArguments)
        guard list.exitCode == 0 else { throw tool.failure("gem list failed", list) }
        let listed = try Self.listed(list.stdout)
        let script = try await tool.run(sibling: "ruby", ["-e", Self.executablesScript])
        guard script.exitCode == 0 else {
            throw tool.failure("Ruby couldn't say which gems have commands", script)
        }
        let executables = try Self.executables(script.stdout)
        let tools = Self.tools(listed, executables: executables)
        state.listed(tools, separate: executables.separate)
        return tools
    }

    // MARK: outdated

    /// The Ruby an update must run on: its version, RubyGems' version and its platforms. Nil versions aren't checked.
    struct Runtime: Equatable, Sendable {
        var ruby: String?
        var rubyGems: String?
        var platforms: [String]

        /// Whether a version from the index can be installed here: for the `ruby` platform or this Mac's, and its Ruby
        /// and RubyGems requirements met.
        func allows(_ version: IndexVersion) -> Bool {
            guard GemEngine.platformMatches(version.platform, local: platforms) else { return false }
            if let ruby, let needs = version.ruby, !GemEngine.satisfies(ruby, needs) { return false }
            if let rubyGems, let needs = version.rubyGems, !GemEngine.satisfies(rubyGems, needs) { return false }
            return true
        }
    }

    /// `checkOutdated()`'s updates, a gem that came with Ruby's included.
    public func listOutdated() async throws -> [Package] { try await checkOutdated().packages }

    /// `gem outdated`'s tools looked up in the compact index, a few at a time; when it names none (it says nothing,
    /// exit 0, when it couldn't reach its source, or when nothing is outdated), every tool. A lookup that fails leaves
    /// that tool out (R6, named in `unchecked` and kept in `couldntCheck`); when none answers, the check fails. A tool
    /// RubyGems.org hasn't got (404) is an answer, not a failure: it's named in `notOnRubyGems` and the engine's note.
    /// An update of a gem that came with Ruby is held back from automatic updates (R19), and stays in the updates for
    /// the person.
    public func checkOutdated() async throws -> OutdatedReport {
        // A check that fails as a whole (its listing included) leaves no per-tool list behind: the failure says it.
        state.checked([:], notListed: [])
        let tools = try await listTools()
        guard !tools.isEmpty else { return OutdatedReport(packages: []) }
        let result = try await tool.run(Self.outdatedArguments)
        guard result.exitCode == 0 else { throw tool.failure("gem outdated failed", result) }
        let named = Set(Self.outdatedNames(result.stdout))
        let candidates = tools.filter { named.contains($0.name) }
        let checked = candidates.isEmpty ? tools : candidates
        let runtime = await runtime()
        let answers = try await concurrentMap(checked.map(\.name), limit: Self.concurrentLookups) { name in
            do {
                return Result<[IndexVersion]?, any Error>.success(try await Self.versions(name, from: registry))
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        var index: [String: Result<[IndexVersion], any Error>] = [:]
        var notListed: Set<String> = []
        for (name, answer) in answers {
            switch answer {
            case .success(let versions?): index[name] = .success(versions)
            case .success(nil): notListed.insert(name)
            case .failure(let error): index[name] = .failure(error)
            }
        }
        let check = try Self.updates(checked, index: index, runtime: runtime, notListed: notListed)
        state.checked(check.couldntCheck, notListed: check.notListed)
        return OutdatedReport(packages: check.updates, unchecked: UncheckedPackages(reasons: check.couldntCheck),
                              held: check.held)
    }

    /// What the last `detect()` read from `gem environment`, else asked now. Without it, only the `ruby` platform
    /// counts and the requirements aren't checked.
    private func runtime() async -> Runtime {
        var environment = state.environment
        if environment == nil, let result = try? await tool.run(Self.environmentArguments), result.exitCode == 0 {
            environment = Self.environment(result.stdout)
        }
        let platforms = environment?.platforms ?? []
        return Runtime(ruby: environment?.rubyVersion, rubyGems: environment?.rubyGemsVersion ?? state.version,
                       platforms: platforms.isEmpty ? ["ruby"] : platforms)
    }

    /// The names in `gem outdated`'s `name (installed < latest)` lines; other lines are skipped (the index decides).
    static func outdatedNames(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let found = entry(line.trimmingCharacters(in: .whitespaces)), found.inside.contains(" < ")
            else { return nil }
            return found.name
        }
    }

    /// A gem's file in RubyGems.org's compact index; nil for a name that isn't a gem name.
    static func indexURL(_ name: String) -> URL? {
        guard PackageNameRules.isValid(name, for: .gem) else { return nil }
        return URL(string: "https://index.rubygems.org/info/\(name)")
    }

    /// One version in the compact index, as much of it as BrewxPort uses.
    struct IndexVersion: Equatable, Sendable {
        let version: String
        /// `arm64-darwin`; nil for the `ruby` platform.
        let platform: String?
        /// The Ruby it needs (`>= 2.6.0`, several joined with `&`); nil when it doesn't say.
        let ruby: String?
        let rubyGems: String?
    }

    /// The versions in one index file: after `---`, `version[-platform] dependencies|key:value,…` per line. A line
    /// that isn't one is skipped. Nil when none is.
    static func indexVersions(_ text: String) -> [IndexVersion]? {
        let versions = text.split(whereSeparator: \.isNewline).compactMap { line -> IndexVersion? in
            guard line != "---", let bar = line.firstIndex(of: "|"),
                  let head = line[..<bar].split(separator: " ").first else { return nil }
            let (version, platform) = head.firstIndex(of: "-").map { dash in
                (String(head[..<dash]), Optional(String(head[head.index(after: dash)...])))
            } ?? (String(head), nil)
            guard EcosystemVersion.isValid(version, scheme: .gem), platform?.isEmpty != true else { return nil }
            var requirements: [Substring: String] = [:]
            for field in line[line.index(after: bar)...].split(separator: ",") {
                guard let colon = field.firstIndex(of: ":") else { continue }
                requirements[field[..<colon]] = String(field[field.index(after: colon)...])
            }
            return IndexVersion(version: version, platform: platform, ruby: requirements["ruby"],
                                rubyGems: requirements["rubygems"])
        }
        return versions.isEmpty ? nil : versions
    }

    /// `name`'s versions in the compact index; nil when RubyGems.org has no such gem (404). The index's other refusals,
    /// being offline and an answer that can't be read are `EngineError`s; anything else (a cancelled task, demo mode's
    /// uncaptured answer) is thrown as it is.
    static func versions(_ name: String, from registry: any RegistryFetching) async throws -> [IndexVersion]? {
        guard let url = indexURL(name) else {
            throw EngineError(engine: .gem, message: "Invalid package name: \(name)")
        }
        guard let data = try await fetchIfFound(url, gem: name, from: registry, what: "RubyGems.org's index") else {
            return nil
        }
        guard let versions = indexVersions(String(decoding: data, as: UTF8.self)) else {
            throw EngineError(engine: .gem, message: "Couldn't read RubyGems.org's index for \(name)")
        }
        return versions
    }

    /// What an outdated check found: the updates, the tools it couldn't look up, the ones RubyGems.org hasn't got, and
    /// the updates held back from automatic updates (a gem that came with Ruby, R19; it's in `updates` too).
    struct Check {
        var updates: [Package] = []
        var couldntCheck: [String: String] = [:]
        /// Sorted.
        var notListed: [String] = []
        var held: [HeldUpdate] = []
    }

    /// The updates the index's answers (by name) give `tools`: each one's newest version `runtime` allows, by
    /// Gem::Version, and not a pre-release for a stable install. It must be newer than the highest copy installed of
    /// any kind, which is what `gem update` updates from: one only newer than the user's older copy, beside Ruby's own
    /// newer one, would be "Nothing to update" every time. The row shows the user's version. A gem that came with
    /// Ruby (R19) is held back from automatic updates. The tools in `notListed` are ones RubyGems.org answered it
    /// hasn't got (404): they're answers, never failures. Throws when no answer came back for any of them.
    static func updates(_ tools: [Gem], index: [String: Result<[IndexVersion], any Error>], runtime: Runtime,
                        notListed: Set<String> = []) throws -> Check {
        var updates: [Package] = []
        var held: [HeldUpdate] = []
        let elsewhere = tools.map(\.name).filter(notListed.contains).sorted()
        let unchecked = try OutdatedLookups.tally(
            tools.filter { !notListed.contains($0.name) }, answers: index, key: \.name, name: \.name,
            noAnswer: { failure in
                // RubyGems.org answering that it hasn't got a tool is an answer: the check didn't fail.
                guard elsewhere.isEmpty else { return nil }
                return EngineError(engine: .gem, message: "BrewxPort couldn't check RubyGems.org for newer versions: "
                                   + (failure.map(OutdatedLookups.describe) ?? "nothing could be looked up."))
            }
        ) { gem, versions in
            let candidates = versions.filter(runtime.allows).map(\.version)
            guard let newer = EcosystemVersion.newerVersion(than: gem.highest, among: candidates, scheme: .gem)
            else { return }
            let row = Package(id: PackageRef(engine: .gem, kind: .tool, name: gem.name), displayName: gem.name,
                              installedVersion: gem.version, latestVersion: newer)
            updates.append(row)
            if gem.shippedWithRuby { held.append(HeldUpdate(package: row, hold: shippedWithRubyHold)) }
        }
        return Check(updates: updates.sorted { $0.id.name < $1.id.name }, couldntCheck: unchecked.reasons,
                     notListed: elsewhere, held: held.sorted { $0.package.id.name < $1.package.id.name })
    }

    // MARK: requirements and platforms

    /// Whether `version` meets `requirement`, Gem::Requirement's way: `op version` (`=` when there's no operator),
    /// several joined with `&`, every one met. `~> 2.1` is `>= 2.1` and `< 3`. A requirement BrewxPort can't read is
    /// never met, so the version is held back.
    static func satisfies(_ version: String, _ requirement: String) -> Bool {
        let parts = requirement.split(separator: "&")
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            guard let (op, wanted) = parsedRequirement(part.trimmingCharacters(in: .whitespaces)) else { return false }
            let order = EcosystemVersion.compare(version, wanted, scheme: .gem)
            switch op {
            case "=": return order == .orderedSame
            case "!=": return order != .orderedSame
            case ">": return order == .orderedDescending
            case "<": return order == .orderedAscending
            case ">=": return order != .orderedAscending
            case "<=": return order != .orderedDescending
            default:  // "~>"
                return order != .orderedAscending
                    && EcosystemVersion.compare(release(version), bump(wanted), scheme: .gem) == .orderedAscending
            }
        }
    }

    private static let operators = ["!=", ">=", "<=", "~>", "=", ">", "<"]

    private static func parsedRequirement(_ text: String) -> (String, String)? {
        let op = operators.first { text.hasPrefix($0) } ?? "="
        let rest = (text.hasPrefix(op) ? String(text.dropFirst(op.count)) : text).trimmingCharacters(in: .whitespaces)
        guard EcosystemVersion.isValid(rest, scheme: .gem), !rest.contains(" ") else { return nil }
        return (op, rest)
    }

    /// Gem::Version's segments: runs of digits and of letters (`1.0.a2` is 1, 0, a, 2).
    private static func segments(_ version: String) -> [Substring] {
        var result: [Substring] = []
        var rest = Substring(version)
        while let start = rest.firstIndex(where: { $0.isASCII && ($0.isNumber || $0.isLetter) }) {
            rest = rest[start...]
            let digits = rest.first!.isNumber
            let run = rest.prefix { $0.isASCII && (digits ? $0.isNumber : $0.isLetter) }
            result.append(run)
            rest = rest[run.endIndex...]
        }
        return result
    }

    /// Gem::Version#release: the segments before the first letter one (`1.0.a2` is `1.0`).
    private static func release(_ version: String) -> String {
        segments(version).prefix { $0.first?.isNumber == true }.joined(separator: ".")
    }

    /// Gem::Version#bump, for `~>`: without its letter segments and then its last one (unless it's the only one), the
    /// new last one plus one (`2.1` gives `3`, `2.1.0` gives `2.2`, `2` gives `3`).
    private static func bump(_ version: String) -> String {
        var parts = segments(version)
        while parts.contains(where: { $0.first?.isLetter == true }) { parts.removeLast() }
        if parts.count > 1 { parts.removeLast() }
        guard let last = parts.popLast(), let number = Int(last) else { return version }
        return (parts.map(String.init) + [String(number + 1)]).joined(separator: ".")
    }

    /// Whether a version for `platform` (nil: `ruby`) installs here, Gem::Platform's way for a Mac: the same OS, the
    /// same CPU (or `universal`), and the same OS version unless either doesn't name one (`arm64-darwin` fits
    /// `arm64-darwin-24`, `arm64-darwin-22` doesn't).
    static func platformMatches(_ platform: String?, local: [String]) -> Bool {
        guard let platform, platform != "ruby" else { return true }
        let wanted = Platform(platform)
        return local.filter { $0 != "ruby" }.map(Platform.init).contains { $0.runs(wanted) }
    }

    /// `cpu-os[-version]`, with `darwin24` read as `darwin` version 24; a single word is an OS (`java`).
    private struct Platform {
        var cpu: String?
        var os: String
        var version: String?

        /// Whether this Mac's platform runs a gem built for `gem`.
        func runs(_ gem: Platform) -> Bool {
            guard os == gem.os else { return false }
            let cpuFits = cpu == gem.cpu || cpu == "universal" || gem.cpu == "universal"
            let versionFits = version == nil || gem.version == nil || version == gem.version
            return cpuFits && versionFits
        }

        init(_ text: String) {
            let parts = text.split(separator: "-", maxSplits: 2).map(String.init)
            if parts.count < 2 {
                os = parts.first ?? text
            } else {
                cpu = parts[0]
                os = parts[1]
                version = parts.count > 2 ? parts[2] : nil
            }
            if os.hasPrefix("darwin"), os.count > 6, os.dropFirst(6).allSatisfy(\.isNumber) {
                version = version ?? String(os.dropFirst(6))
                os = "darwin"
            }
        }
    }

    // MARK: search

    /// `gem search --remote`, which reads the gem sources gem is set up for. A query gem would read as an option
    /// finds nothing, without asking.
    public func search(_ query: String) async throws -> [Package] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError(engine: .gem, message: "Search query is empty") }
        guard !text.hasPrefix("-") else { return [] }
        let result = try await tool.run(Self.searchArguments + [Self.pattern(text)])
        guard result.exitCode == 0 else { throw tool.failure("gem search failed", result) }
        return Self.searchResults(result.stdout, query: text)
    }

    /// The query as gem's regular expression for that text: its special characters escaped.
    static func pattern(_ query: String) -> String {
        var escaped = ""
        for character in query {
            if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// The gems in `gem search`'s output (`name (latest)`, alphabetical): the exact name first, then names that start
    /// with the query, then the rest, `searchLimit` at most. Other lines, and names gem couldn't install by name,
    /// are left out.
    static func searchResults(_ output: String, query: String) -> [Package] {
        let rows = output.split(whereSeparator: \.isNewline).compactMap { line -> Package? in
            guard let found = entry(line.trimmingCharacters(in: .whitespaces)),
                  PackageNameRules.isValid(found.name, for: .gem) else { return nil }
            let name = found.name
            let latest = found.inside.split(separator: " ").first.map(String.init)
            return Package(id: PackageRef(engine: .gem, kind: .tool, name: name), displayName: name,
                           latestVersion: latest.flatMap { EcosystemVersion.isValid($0, scheme: .gem) ? $0 : nil })
        }
        let needle = query.lowercased()
        func rank(_ row: Package) -> Int {
            let name = row.id.name.lowercased()
            return name == needle ? 0 : (name.hasPrefix(needle) ? 1 : 2)
        }
        return Array(rows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element).prefix(searchLimit))
    }

    // MARK: info

    /// RubyGems.org's API answer for one gem, as much of it as BrewxPort uses.
    private struct GemAnswer: Decodable {
        let name: String?
        let version: String?
        let info: String?
        let homepageURI: String?
        let sourceCodeURI: String?
        let projectURI: String?

        enum CodingKeys: String, CodingKey {
            case name, version, info
            case homepageURI = "homepage_uri"
            case sourceCodeURI = "source_code_uri"
            case projectURI = "project_uri"
        }
    }

    /// The gem on RubyGems.org: its summary, home page (else source code, else its RubyGems.org page) and newest
    /// version, with the installed version from the last listing.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .gem, ref.kind == .tool else {
            throw EngineError(engine: .gem, message: "Package belongs to a different engine")
        }
        try PackageNameRules.validate(ref.name, for: .gem)
        guard let url = URL(string: "https://rubygems.org/api/v1/gems/\(ref.name).json") else {
            throw EngineError(engine: .gem, message: "Invalid package name: \(ref.name)")
        }
        let data = try await Self.fetch(url, gem: ref.name, from: registry, what: "RubyGems.org")
        let answer: GemAnswer
        do {
            answer = try JSONDecoder().decode(GemAnswer.self, from: data)
        } catch {
            throw EngineError(engine: .gem, message: "Couldn't read RubyGems.org's answer for \(ref.name)")
        }
        guard let latest = nonBlank(answer.version) else {
            throw EngineError(engine: .gem, message: "RubyGems.org had no information for \(ref.name)")
        }
        let summary = answer.info.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let homepage = webURL(answer.homepageURI) ?? webURL(answer.sourceCodeURI) ?? webURL(answer.projectURI)
            ?? URL(string: "https://rubygems.org/gems/\(ref.name)")
        return PackageDetails(ref: ref, summary: nonBlank(summary), homepage: homepage,
                              installedVersion: state.tool(ref.name)?.version, latestVersion: latest,
                              reportedName: nonBlank(answer.name))
    }

    // MARK: commands

    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    /// `install` and `update` from gem's sources only (`--remote`, R16), without documentation; `uninstall` of every
    /// version and its executables, refused when a dependent needs the gem, and confirmed afterwards by the `ruby`
    /// beside gem (`confirmationScript`). Each takes several names. An update is only for tools the last listing
    /// showed (`upgradable`), and a removal never for one that came with Ruby (`shippedWithRuby`, R19).
    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        // Without names, `gem update` would update every gem, Ruby's default gems too.
        guard !refs.isEmpty else { throw EngineError(engine: .gem, message: "No packages given") }
        guard refs.allSatisfy({ $0.engine == .gem && $0.kind == .tool }) else {
            throw EngineError(engine: .gem, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .gem, message: "RubyGems installs the latest version only")
        }
        guard options.variants.isEmpty else { throw EngineError(engine: .gem, message: "RubyGems has no variants") }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .gem, message: "RubyGems commands take no extra arguments")
        }
        try access.requireWritable(for: op, engine: .gem)
        for ref in refs { try PackageNameRules.validate(ref.name, for: .gem) }
        let names = refs.map(\.name)
        switch op {
        case .install: return try tool.command(Self.installArguments + names)
        case .upgrade:
            try upgradable(names)
            return try tool.command(["update", "--remote", "--no-document"] + names)
        case .remove:
            // R19: in a gem folder Ruby shares, `--all` would take Ruby's own copy of a bundled gem with it.
            if let shipped = names.first(where: { state.tool($0)?.shippedWithRuby == true }) {
                throw EngineError(engine: .gem, message: "\(shipped) came with Ruby; removing it would break Ruby's "
                                  + "own copy.")
            }
            let confirmation = ["-e", Self.confirmationScript, "--"] + names
            return try tool.command(Self.uninstallArguments + names,
                                    confirmedBy: (sibling: "ruby", arguments: confirmation))
        case .repair:
            throw EngineError(engine: .gem, message: "RubyGems repairs its tools only through Repair tools")
        case .markRequested, .markDependency:
            throw EngineError(engine: .gem, message: "RubyGems can't mark packages")
        }
    }

    /// Refuses, in one line, an update of a gem the last listing didn't show as a tool: a gem that came with Ruby
    /// (updating one installs a second copy beside Ruby's, R18), a library, anything before a listing.
    private func upgradable(_ names: [String]) throws {
        for name in names where state.tool(name) == nil {
            throw EngineError(engine: .gem, message: "BrewxPort can't find \(name) among RubyGems' installed tools, "
                              + "so it doesn't update it.")
        }
    }

    // MARK: helpers

    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .gem, kind: .tool, name: name) }

    /// One GET to RubyGems.org (`what` names which part, for messages). 404 means no such gem; its other refusals and
    /// being offline are `EngineError`s; anything else (a cancelled task, demo mode's uncaptured answer) is thrown as
    /// it is.
    private static func fetch(_ url: URL, gem name: String, from registry: any RegistryFetching, what: String)
        async throws -> Data {
        guard let data = try await fetchIfFound(url, gem: name, from: registry, what: what) else {
            throw EngineError(engine: .gem, message: "RubyGems.org has no gem named \(name)")
        }
        return data
    }

    /// `fetch`, with nil for a 404: RubyGems.org has no such gem.
    private static func fetchIfFound(_ url: URL, gem name: String, from registry: any RegistryFetching, what: String)
        async throws -> Data? {
        do {
            return try await registry.get(url)
        } catch RegistryFetchError.status(404) {
            return nil
        } catch let error as RegistryFetchError {
            throw EngineError(engine: .gem, message: "\(what) didn't answer for \(name): \(error)")
        } catch let error as URLError where error.code != .cancelled {
            throw EngineError(engine: .gem, message: "Couldn't reach RubyGems.org: \(error.localizedDescription)")
        }
    }

    /// What the last `detect()`, listing and outdated check found, shared by copies of the engine.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var detectedVersion: String?
        private var detectedEnvironment: Environment?
        private var detectedSource: RubySource?
        private var tools: [String: Gem] = [:]
        private var separateFolder: Bool?
        private var notChecked: [String: String] = [:]

        var version: String? { lock.withLock { detectedVersion } }
        var environment: Environment? { lock.withLock { detectedEnvironment } }
        var source: RubySource? { lock.withLock { detectedSource } }
        var unchecked: [String: String] { lock.withLock { notChecked } }
        /// Whether the last listing found gem installing outside Ruby's own gem folder; nil before one.
        var separate: Bool? { lock.withLock { separateFolder } }
        var shipped: Set<String> { lock.withLock { Set(tools.values.filter(\.shippedWithRuby).map(\.name)) } }

        func detected(version: String?, environment: Environment?, source: RubySource?) {
            lock.withLock {
                detectedVersion = version
                detectedEnvironment = environment
                detectedSource = source
            }
        }

        func listed(_ found: [Gem], separate: Bool) {
            let map = Dictionary(found.map { ($0.name, $0) }) { first, _ in first }
            lock.withLock {
                tools = map
                separateFolder = separate
            }
        }

        /// The tools the last outdated check found RubyGems.org hasn't got, sorted.
        var notListed: [String] { lock.withLock { elsewhere } }
        private var elsewhere: [String] = []

        func checked(_ names: [String: String], notListed: [String]) {
            lock.withLock {
                notChecked = names
                elsewhere = notListed
            }
        }

        func tool(_ name: String) -> Gem? { lock.withLock { tools[name] } }
    }
}

// MARK: Task 10: runtime and repair

extension GemEngine: RuntimeReporting, ToolRepairing, EngineNoteReporting {
    /// Homebrew's Ruby formula (`ruby`, or a keg-only `ruby@3.4`) when the last detect found gem running it: a Ruby
    /// minor update moves the gem folder, which leaves every gem behind. Throws when the last detect couldn't say which
    /// Ruby gem runs (none yet, `gem --version` failing, no `gem environment` from a gem whose path doesn't say, or a
    /// Homebrew Ruby whose formula can't be read): the caller then holds the update (R29's careful reading), rather
    /// than taking it as "none".
    public func runtimeUses() async throws -> [RuntimeUse] {
        let unknown = EngineError(engine: .gem, message: "BrewxPort couldn't tell which Ruby gem runs.")
        guard state.version != nil, let source = state.source else { throw unknown }
        guard source == .homebrew else {
            if source == .other, state.environment == nil { throw unknown }
            return []
        }
        guard let formula = [state.environment?.rubyExecutable, tool.executable?.path].compactMap({ $0 })
            .lazy.compactMap({ HomebrewFormula.owning($0) }).first else { throw unknown }
        return [RuntimeUse(formula: formula)]
    }

    /// The tools RubyGems.org hasn't got (`notOnRubyGems`), for the engine's page: "rake isn't on RubyGems.org, so
    /// BrewxPort can't check it for updates." Nil when there are none.
    public var note: String? {
        let names = notOnRubyGems
        guard let last = names.last else { return nil }
        guard names.count > 1 else { return "\(last) isn't on RubyGems.org, so BrewxPort can't check it for updates." }
        return names.dropLast().joined(separator: ", ") + " and \(last) aren't on RubyGems.org, so BrewxPort can't "
            + "check them for updates."
    }

    /// `gem install --remote --no-document <tool>` for each tool, one per command, sorted. A new Ruby minor version has
    /// a gem folder of its own, so the tools are installed again into it (`gem pristine` only restores gems the
    /// current Ruby already has). A gem that came with Ruby (R19) is left out.
    public func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        try access.requireWritable(for: .repair, engine: .gem)
        let names = Set(tools).subtracting(state.shipped).sorted()
        let repairable = names.filter { Self.repairRefusal($0) == nil }
        guard !repairable.isEmpty || repairable.count != names.count else {
            throw EngineError(engine: .gem, message: "RubyGems has no tools BrewxPort can repair")
        }
        return try repairable.map { name in
            RepairCommand(tool: name, spec: try tool.command(Self.installArguments + [name]))
        }
    }

    /// The names gem wouldn't install by name, each with why; the others are all installed again (a gem that came
    /// with Ruby isn't the person's to repair, and is left out without a word).
    public func repairRefusals(for tools: [String]) -> [String: String] {
        var refusals: [String: String] = [:]
        for name in Set(tools).subtracting(state.shipped) {
            if let reason = Self.repairRefusal(name) { refusals[name] = reason }
        }
        return refusals
    }

    /// Why `name` isn't installed again by name; nil when it can be.
    static func repairRefusal(_ name: String) -> String? {
        PackageNameRules.isValid(name, for: .gem) ? nil
            : "BrewxPort doesn't repair \(name): it isn't a name RubyGems installs by."
    }
}
