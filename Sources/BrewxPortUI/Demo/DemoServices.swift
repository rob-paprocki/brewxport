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

    /// `delay` is `DemoRunExecutor`'s; tests pass `.zero`. `bundleResources` is where the bundled fixtures would be.
    @MainActor static func make(_ options: DemoOptions, delay: Duration,
                                bundleResources: URL? = Bundle.main.resourceURL) throws -> Services {
        guard let fixtures = fixturesDirectory(options, bundleResources: bundleResources) else {
            throw DemoServicesError.noFixtures
        }
        let host = options.host
        let runner = FixtureRunner(fixtures: fixtures, host: host)
        let binDirs = binDirectories(host)
        func tool(_ id: EngineID, _ name: String) -> URL { URL(fileURLWithPath: "\(binDirs[id]!)/\(name)") }
        let real: [any Engine] = [
            HomebrewEngine(runner: runner, executable: tool(.homebrew, "brew"), arch: host),
            NanobrewEngine(runner: runner, executable: tool(.nanobrew, "nb")),
            MacPortsEngine(runner: runner, executable: tool(.macports, "port")),
            MasEngine(runner: runner, executable: tool(.mas, "mas")),
        ]
        let (installed, outdated, taps) = try readInventory(real)
        let inventory = DemoInventory(installed: installed, outdated: outdated, taps: taps)
        let engines: [any Engine] = real.map { DemoEngine(wrapping: $0, runner: runner, inventory: inventory, host: host) }

        // Tools on the PATH are the installed packages' own names, as the fixtures had them at launch.
        var onDisk = Set<String>()
        for (id, packages) in installed where id != .mas {
            for package in packages { onDisk.insert("\(binDirs[id]!)/\(package.id.name)") }
        }
        let files = onDisk

        // One provider: the executor asks it, and BrewxPortAppModel points it at the run controller.
        let passwords = PromptPasswordProvider()
        return Services(
            engines: engines, catalog: PackageCatalog(engines: engines, arch: host),
            executor: DemoRunExecutor(provider: passwords, inventory: inventory, delay: delay), helper: nil,
            passwords: passwords, isAdministrator: { true }, store: MemoryStore(), path: DemoPath(),
            fileExists: { files.contains($0) }, host: host,
            hostInfo: HostInfo(appleSilicon: host == .arm64,
                               macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            cltPresent: { true }, receipts: NoReceipts(), setupProblem: nil, isDemo: true,
            scheduler: DemoScheduler(), notifier: DemoNotifier(), loginItem: DemoLoginItem(),
            conditions: DemoConditions())
    }

    /// Where each engine's tools live in demo mode. Homebrew's prefix follows the demo architecture.
    static func binDirectories(_ host: Arch) -> [EngineID: String] {
        [.homebrew: host == .x86_64 ? "/usr/local/bin" : "/opt/homebrew/bin",
         .nanobrew: "/opt/nanobrew/prefix/bin",
         .macports: "/opt/local/bin",
         .mas: "/opt/homebrew/bin"]
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
                var outdated: [EngineID: [Package]] = [:]
                var taps: [String] = []
                for engine in engines {
                    installed[engine.id] = try await engine.listInstalled()
                    outdated[engine.id] = try await engine.listOutdated()
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
        typealias Lists = (installed: [EngineID: [Package]], outdated: [EngineID: [Package]], taps: [String])
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
