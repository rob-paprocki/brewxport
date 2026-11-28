import Foundation
import BrewxPortCore
import BrewxPortRun

public enum DemoServicesError: Error, Equatable, Sendable {
    /// Neither `--demo-fixtures` nor the bundle's `Contents/Resources/DemoFixtures` is a directory.
    case noFixtures
}

/// Services for `--demo`: the real engines and parsers on captured output, simulated runs, no helper, nothing kept.
/// Nothing here launches a process, talks to launchd or XPC, reads or writes the user's preferences, or schedules,
/// notifies or registers a login item.
public enum DemoServices {
    public static let helperText = "Demo mode: BrewxPort's helper isn't used."
    public static let passwordNote = "Demo mode: type anything. Nothing is checked or kept."
    public static let noFixturesMessage =
        "Demo mode needs BrewxPort's captured engine output, and this copy doesn't have it. "
        + "From the repository, run scripts/demo.sh."
    public static let pathEntries = ["/opt/homebrew/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin", "/usr/bin", "/bin"]

    @MainActor public static func make(_ options: DemoOptions) throws -> Services {
        try make(options, delay: .milliseconds(400))
    }

    /// `delay` and `pause` are `DemoRunExecutor`'s; tests pass a `.zero` delay. `bundleResources` is where the bundled
    /// fixtures would be.
    @MainActor static func make(_ options: DemoOptions, delay: Duration,
                                pause: @escaping DemoRunExecutor.Pause = DemoRunExecutor.taskSleep,
                                bundleResources: URL? = Bundle.main.resourceURL) throws -> Services {
        guard let fixtures = fixturesDirectory(options, bundleResources: bundleResources) else {
            throw DemoServicesError.noFixtures
        }
        let host = options.host
        let runner = FixtureRunner(fixtures: fixtures, host: host, rubySharesGemFolder: options.states)
        func tool(_ id: EngineID, _ name: String) -> URL {
            URL(fileURLWithPath: "\(binDirectory(id, host: host))/\(name)")
        }
        // npm is Homebrew's node's, on the captures from Fixtures/npm; pipx and uv are Homebrew's, on Fixtures/pipx and
        // Fixtures/uv, with the fixtures' PyPI answers. Cargo is Homebrew rustup's, on Fixtures/cargo with the captured
        // record (never this Mac's), install root (CARGO_HOME as captured) and crates.io answers. Bun is Homebrew's,
        // on Fixtures/bun with the npm registry's captured search. RubyGems is Homebrew Ruby's, on Fixtures/gem with
        // the captured compact index and API answers. Mint is Homebrew's, on Fixtures/mint with Mint's captured
        // metadata (never this Mac's), its folders as captured, and the captured tag lookup through Apple's git.
        // `--demo-missing` engines aren't installed: nothing to list, and their pages show Set Up. `--demo-states` layers
        // on what the captures can't show (`DemoStates`).
        // The home of the account the fixtures were captured under. It's assembled at runtime because the release
        // build rejects any `/Users/` text in the binary.
        let captureHome = NSString.path(withComponents: ["/", "Users", "tester"])
        let languages: [any Engine] = EngineID.allCases.filter(\.isLanguage).map { (id: EngineID) -> any Engine in
            if options.missing.contains(id) { return NotInstalledEngine(id: id) }
            return switch id {
            case .npm:
                NpmEngine(runner: runner, executable: tool(.npm, "npm"), homebrewNode: { _ in true },
                          nodeFormula: { _ in "node" }, isVolta: { _ in false })
            // No pyvenv.cfg was captured (T13), and the demo never reads this Mac's.
            case .pipx: PipxEngine(runner: runner, registry: runner, executable: tool(.pipx, "pipx"),
                                   readToolFile: { _ in nil })
            // No receipt was captured (T13), and the demo never reads this Mac's: uv's Repair says why it can't.
            case .uv: UvEngine(runner: runner, registry: runner, executable: tool(.uv, "uv"), readToolFile: { _ in nil },
                               toolPathExists: { _ in true })
            case .cargo:
                CargoEngine(runner: runner, registry: runner, executable: tool(.cargo, "cargo"),
                            captured: ["CARGO_HOME": "\(captureHome)/.cargo"],
                            readRecord: { try runner.cargoRecord($0) },
                            // The demo's crates.io answers are captures: no crawler policy to keep, so no waits.
                            apiPacing: CargoEngine.APIPacing(spacing: .zero, budget: .seconds(20)))
            case .bun: BunEngine(runner: runner, registry: runner, executable: tool(.bun, "bun"))
            case .gem: GemEngine(runner: runner, registry: runner, executable: tool(.gem, "gem"))
            case .mint:
                MintEngine(runner: runner, executable: tool(.mint, "mint"), git: URL(fileURLWithPath: "/usr/bin/git"),
                           captured: ["MINT_PATH": "\(captureHome)/.mint", "MINT_LINK_PATH": "\(captureHome)/.mint/bin"],
                           readMetadata: { try runner.mintMetadata($0) })
            // Not reached: only language engines are in this list, and each has its engine.
            case .homebrew, .nanobrew, .macports, .mas: NotInstalledEngine(id: id)
            }
        }
        let real: [any Engine] = [
            HomebrewEngine(runner: runner, executable: tool(.homebrew, "brew"), arch: host),
            NanobrewEngine(runner: runner, executable: tool(.nanobrew, "nb")),
            MacPortsEngine(runner: runner, executable: tool(.macports, "port")),
            MasEngine(runner: runner, executable: tool(.mas, "mas")),
        ] + languages
        let lists = try readInventory(real)
        var installed = lists.installed
        var outdated = lists.outdated
        if options.states { DemoStates.apply(installed: &installed, outdated: &outdated, fixtures: fixtures) }
        let inventory = DemoInventory(installed: installed, outdated: outdated, taps: lists.taps)
        let engines: [any Engine] = real.map { DemoEngine(wrapping: $0, runner: runner, inventory: inventory, host: host) }

        // Tools on the PATH are the installed packages' own names, as the fixtures had them at launch.
        var onDisk = Set<String>()
        for (id, packages) in installed where id != .mas {
            for package in packages { onDisk.insert("\(binDirectory(id, host: host))/\(package.id.name)") }
        }
        let files = onDisk

        // One provider: the executor asks it, and BrewxPortAppModel points it at the run controller.
        let passwords = PromptPasswordProvider()
        return Services(
            engines: engines, catalog: PackageCatalog(engines: engines, arch: host),
            executor: DemoRunExecutor(provider: passwords, inventory: inventory, delay: delay, pause: pause),
            helper: nil,
            passwords: passwords, isAdministrator: { true }, store: MemoryStore(), path: DemoPath(),
            fileExists: { files.contains($0) }, host: host,
            hostInfo: HostInfo(appleSilicon: host == .arm64,
                               macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            cltPresent: { true }, receipts: NoReceipts(), setupProblem: nil, isDemo: true,
            scheduler: DemoScheduler(), notifier: DemoNotifier(), loginItem: DemoLoginItem(),
            conditions: DemoConditions())
    }

    /// Where each engine's tools live in demo mode, for every engine: the switch has no default, so a new engine
    /// doesn't build until it has a folder. Homebrew's prefix follows the demo architecture; npm, pipx, uv, bun, gem
    /// and mint are Homebrew's, and cargo is Homebrew's keg-only rustup's, as captured. (A real pipx or uv puts its
    /// tools in `~/.local/bin`, cargo in `~/.cargo/bin`, bun in `~/.bun/bin` and mint in `~/.mint/bin`; the demo keeps
    /// them beside the manager.)
    static func binDirectory(_ id: EngineID, host: Arch) -> String {
        let prefix = host == .x86_64 ? "/usr/local" : "/opt/homebrew"
        switch id {
        case .homebrew, .npm, .pipx, .uv, .bun, .gem, .mint: return prefix + "/bin"
        case .nanobrew: return "/opt/nanobrew/prefix/bin"
        case .macports: return "/opt/local/bin"
        case .mas: return "/opt/homebrew/bin"
        case .cargo: return prefix + "/opt/rustup/bin"
        }
    }

    static func fixturesDirectory(_ options: DemoOptions, bundleResources: URL?) -> URL? {
        let candidate = options.fixtures ?? bundleResources?.appendingPathComponent("DemoFixtures")
        var isDirectory: ObjCBool = false
        guard let candidate, FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return candidate
    }

    /// Reads every engine's installed and outdated lists, and Homebrew's taps, once, through the real parsers. `make` is synchronous
    /// (the app needs its services before the window), so this waits for a detached task; the fixture runner only
    /// reads files, so it's quick and never needs the main actor.
    private static func readInventory(_ engines: [any Engine]) throws -> InventoryBox.Lists {
        let box = InventoryBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                var installed: [EngineID: [Package]] = [:]
                var outdated: [EngineID: OutdatedReport] = [:]
                var taps: [String] = []
                for engine in engines {
                    installed[engine.id] = try await engine.listInstalled()
                    outdated[engine.id] = try await engine.checkOutdated()
                    if let tapping = engine as? any TapListing { taps += try await tapping.listTaps() }
                }
                box.set(.success((installed, outdated, taps)))
            } catch {
                box.set(.failure(error))
            }
            done.signal()
        }
        done.wait()
        return try box.get().get()
    }

    private final class InventoryBox: @unchecked Sendable {
        typealias Lists = (installed: [EngineID: [Package]], outdated: [EngineID: OutdatedReport], taps: [String])
        private let lock = NSLock()
        private var value: Result<Lists, any Error> = .failure(CancellationError())
        func set(_ value: Result<Lists, any Error>) { lock.withLock { self.value = value } }
        func get() -> Result<Lists, any Error> { lock.withLock { value } }
    }
}

/// The files `--demo-bundle` opens. Neither is written anywhere: `"inventory"` is built in memory from the demo's
/// installed lists and taps by `BundleExporter`, the same as File > Export Bundle; `"brewfile"` is the captured
/// `brewfile/dump-describe.Brewfile` from the fixtures, a real `brew bundle dump` with description
/// comments, so the demo shows a Brewfile as people's machines write it.
public enum DemoSamples {
    public static let names = ["inventory", "brewfile"]
    static let inventoryFileName = "Demo inventory.brewxportbundle"
    static let brewfilePath = "brewfile/dump-describe.Brewfile"

    /// The sample's bytes and the file name to show. Nil for a name not in `names`, for `"brewfile"` without a
    /// fixtures directory or when the file can't be read. `host` is the bundle's arch (the demo's `--demo-arch`).
    public static func data(_ name: String, catalog: any PackageQuerying, fixtures: URL?, host: Arch = .current,
                            appVersion: String = BundleFile.appVersion(Bundle.main.infoDictionary)) async
        -> (data: Data, fileName: String)? {
        switch name {
        case "inventory":
            var packages: [Package] = []
            for await outcome in catalog.stream(.installed) {
                if case .success(let found) = outcome.result { packages += found }
            }
            let taps = (try? await catalog.installedTaps()) ?? []
            let made = BundleExporter.make(installed: packages, taps: taps, appVersion: appVersion, arch: host)
            guard let data = try? made.bundle.encoded() else { return nil }
            return (data, inventoryFileName)
        case "brewfile":
            guard let fixtures,
                  let data = FileManager.default.contents(atPath: fixtures.appendingPathComponent(brewfilePath).path)
            else { return nil }
            return (data, (brewfilePath as NSString).lastPathComponent)
        default:
            return nil
        }
    }
}

/// The PATH a demo window shows: fixed, as if read from the login shell.
struct DemoPath: PathResolving {
    func resolve() async -> ResolvedPath { ResolvedPath(entries: DemoServices.pathEntries, source: .loginShell) }
}
