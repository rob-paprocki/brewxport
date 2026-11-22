import Foundation
import Testing
import BrewxPortCore
@testable import BrewxPortRun

/// Everything the runner touches, faked. Commands are recorded as `[path] + arguments`; the plist and the
/// placeholder live in a per-test temp folder, never at their real paths.
final class SetupWorld: @unchecked Sendable {
    let lock = NSLock()
    let root: URL
    let downloads: URL
    let plistPath: String
    let placeholderPath: String

    var releaseJSON: [SetupTarget: String] = [:]
    var payload = Data("pretend installer bytes".utf8)
    var downloadBytes: Data?
    var downloadError: (any Error)?
    var fetchError: (any Error)?
    var installAfterDownload: String?
    var installerCode: Int32 = 0
    var spctlText: String?
    var softwareUpdateList = "softwareupdate-list-clt.txt"
    var softwareUpdateCode: Int32 = 0
    /// A file the (fake) installer also puts down, such as Homebrew's /etc/paths.d entry.
    var installerAlsoCreates: String?
    var nanobrewDir: PathInfo = .missing
    var optDir: PathInfo = .directory(owner: 0)
    var pkgutilCode: Int32 = 0
    var spctlCode: Int32?
    var failCommand: String?
    var rmdirSucceeds = true
    /// Text served for `*.sha256` downloads; nil serves "<payload sha>  <name>".
    var sidecarText: String?

    private(set) var calls: [[String]] = []
    private(set) var fetched: [URL] = []
    private(set) var logs: [String] = []
    private(set) var installed: Set<String> = []
    private(set) var plistAtInstall: [String: String]?
    private(set) var plistModeAtInstall: Int?
    private(set) var placeholderSeenByList = false
    private(set) var nbMoved = false
    private(set) var downloadLimits: [String: Int] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        downloads = root.appendingPathComponent("BrewxPort/Downloads")
        plistPath = root.appendingPathComponent("homebrew_pkg_user.plist").path
        placeholderPath = root.appendingPathComponent("clt-placeholder").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for target in [SetupTarget.homebrew, .macports, .nanobrew] {
            releaseJSON[target] = try GitHubReleaseTests.fixtureText(target.rawValue)
        }
        let digest = Self.sha(payload)
        releaseJSON[.homebrew] = releaseJSON[.homebrew]!.replacingOccurrences(
            of: "af0827528fda9e8b653ac57815e1a003af588b7153749e8eb23d474afc60976c", with: digest)
        releaseJSON[.macports] = releaseJSON[.macports]!.replacingOccurrences(
            of: "87b2e87ed7adc4aca947b42eb7ff991614cc0edfccb486237f2bbc75f28aae63", with: digest)
        releaseJSON[.nanobrew] = releaseJSON[.nanobrew]!.replacingOccurrences(
            of: "b577bcc573c83473239a17881de404550e5c2df3fdfe6913a116a1c290993281", with: digest)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func sha(_ data: Data) -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try! EngineSetupTrust.sha256(of: file)
    }

    func markInstalled(_ path: String) { _ = lock.withLock { installed.insert(path) } }

    /// Files left in the downloads folder, and any hand-off folders beside it.
    var leftovers: [String] {
        let fm = FileManager.default
        let inDownloads = (try? fm.contentsOfDirectory(atPath: downloads.path)) ?? []
        let beside = ((try? fm.contentsOfDirectory(atPath: downloads.deletingLastPathComponent().path)) ?? [])
            .filter { $0 != "Downloads" }
        return inDownloads + beside
    }

    func commands(_ path: String) -> [[String]] { lock.withLock { calls.filter { $0.first == path } } }

    func runner(host: HostInfo = HostInfo(appleSilicon: true, macOSMajor: 15)) -> EngineSetupRunner {
        EngineSetupRunner(
            fetch: { url in
                let (error, json) = self.lock.withLock { () -> ((any Error)?, String?) in
                    self.fetched.append(url)
                    let target = SetupTarget.allCases.first { $0.repo.map { url.path.contains($0) } ?? false }
                    return (self.fetchError, target.flatMap { self.releaseJSON[$0] })
                }
                if let error { throw error }
                return Data((json ?? "{}").utf8)
            },
            download: { url, destination, maxBytes in
                self.lock.withLock { self.downloadLimits[url.lastPathComponent] = maxBytes }
                if url.lastPathComponent.hasSuffix(".sha256") {
                    let text = self.lock.withLock { self.sidecarText }
                        ?? "\(SetupWorld.sha(self.payload))  \(url.lastPathComponent.dropLast(7))\n"
                    try Data(text.utf8).write(to: destination)
                    return
                }
                let (bytes, error, install) = self.lock.withLock {
                    (self.downloadBytes ?? self.payload, self.downloadError, self.installAfterDownload)
                }
                if let error {
                    try Data(bytes.prefix(4)).write(to: destination)
                    throw error
                }
                try bytes.write(to: destination)
                if let install { self.markInstalled(install) }
            },
            run: { path, arguments in self.run(path, arguments) },
            exists: { path in self.lock.withLock { self.installed.contains(path) } },
            inspect: { path in
                self.lock.withLock {
                    if path == "/opt/nanobrew" { return self.nanobrewDir }
                    if path == "/opt" { return self.optDir }
                    if path == "/opt/nanobrew/prefix/bin/nb", self.nbMoved { return .file(owner: 502, mode: 0o755) }
                    return .missing
                }
            },
            makeDirectory: { path in
                self.lock.withLock { self.calls.append(["mkdir(2)", path]) }
                return true
            },
            giveDirectory: { path, uid in
                self.lock.withLock { self.calls.append(["give", path, "\(uid)"]) }
                return true
            },
            removeDirectory: { path in
                self.lock.withLock {
                    self.calls.append(["rmdir(2)", path])
                    return self.rmdirSucceeds
                }
            },
            host: host,
            downloads: downloads,
            homebrewPlistPath: plistPath,
            cltPlaceholderPath: placeholderPath)
    }

    func log(_ line: String) { lock.withLock { logs.append(line) } }

    private func run(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let fail = lock.withLock { () -> Bool in
            calls.append([path] + arguments)
            return failCommand.map { ([path] + arguments).contains($0) } ?? false
        }
        if fail { return (1, "failed") }
        switch path {
        case "/usr/sbin/pkgutil":
            let engine = arguments.last!.contains("MacPorts") ? "macports" : "homebrew"
            return (lock.withLock { pkgutilCode }, try! EngineSetupTrustTests.fixture("pkgutil-\(engine).txt"))
        case "/usr/sbin/spctl":
            let engine = arguments.last!.contains("MacPorts") ? "macports" : "homebrew"
            let (override, code) = lock.withLock { (spctlText, spctlCode) }
            let text = override ?? (try! EngineSetupTrustTests.fixture("spctl-\(engine).txt"))
            return (code ?? (text.contains("rejected") ? 3 : 0), text)
        case "/usr/sbin/installer":
            if let data = FileManager.default.contents(atPath: plistPath),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                let mode = (try? FileManager.default.attributesOfItem(atPath: plistPath)[.posixPermissions]) as? Int
                lock.withLock {
                    plistAtInstall = dict
                    plistModeAtInstall = mode
                }
            }
            let code = lock.withLock { installerCode }
            if code == 0 {
                if let extra = lock.withLock({ installerAlsoCreates }) { markInstalled(extra) }
                let pkg = arguments[1]
                markInstalled(pkg.hasSuffix("Homebrew.pkg") ? "/opt/homebrew/bin/brew" : "/opt/local/bin/port")
            }
            return (code, code == 0 ? "installer: The install was successful." : "installer: The install failed.")
        case "/usr/sbin/softwareupdate":
            if arguments == ["-l"] {
                let seen = FileManager.default.fileExists(atPath: placeholderPath)
                let name = lock.withLock {
                    placeholderSeenByList = seen
                    return softwareUpdateList
                }
                let code = lock.withLock { softwareUpdateCode }
                return (code, try! EngineSetupTrustTests.fixture(name))
            }
            markInstalled(CommandLineTools.marker)
            return (0, "Done.")
        case "/usr/bin/sudo":
            if arguments.count > 3, arguments[2] == "/bin/mv" { lock.withLock { nbMoved = true } }
            if arguments.count > 2, arguments[2] == "/bin/rmdir", !lock.withLock({ rmdirSucceeds }) { return (1, "not empty") }
            return (0, "")
        default:
            return (0, "")
        }
    }
}

@Suite struct EngineSetupRunnerTests {
    static func outcome(_ world: SetupWorld, _ target: SetupTarget, uid: uid_t = 502, user: String = "alice",
                        host: HostInfo = HostInfo(appleSilicon: true, macOSMajor: 15)) async -> SetupError? {
        do {
            try await world.runner(host: host).setUp(target, forUID: uid, userName: user) { world.log($0) }
            return nil
        } catch {
            return error
        }
    }

    // MARK: Homebrew

    @Test func homebrewHappyPath() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .homebrew)
        #expect(error == nil)
        #expect(world.fetched == [URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!])
        let installs = world.commands("/usr/sbin/installer")
        #expect(installs.count == 1)
        let install = try #require(installs.first)
        #expect(install.count == 5)
        #expect(install[1] == "-pkg" && install[3] == "-target" && install[4] == "/")
        #expect(install[2].hasPrefix(world.downloads.path + "/"))
        #expect(install[2].hasSuffix("-Homebrew.pkg"))
        // Verified before installing.
        let order = world.calls.map(\.first!)
        #expect(order == ["/usr/sbin/pkgutil", "/usr/sbin/spctl", "/usr/sbin/installer"])
        #expect(world.plistAtInstall == ["HOMEBREW_PKG_USER": "alice"])
        #expect(world.plistModeAtInstall == 0o600)
        #expect(!FileManager.default.fileExists(atPath: world.plistPath))
        #expect(world.leftovers.isEmpty)
        #expect(world.logs.contains("Downloading Homebrew 7.0.15…"))
        #expect(world.logs.contains("Checked the download against GitHub's checksum."))
        #expect(world.logs.contains("Apple's notary service accepted the installer."))
        #expect(world.logs.contains("Installing…"))
    }

    @Test func homebrewForRequestingUser() async throws {
        let world = try SetupWorld()
        // Whoever is at the console (or anyone else) left their own override behind.
        let planted = try HomebrewPkgUser.plist(user: "console-user")
        try planted.write(to: URL(fileURLWithPath: world.plistPath))
        let error = await Self.outcome(world, .homebrew, uid: 502, user: "alice")
        #expect(error == nil)
        #expect(world.plistAtInstall == ["HOMEBREW_PKG_USER": "alice"])
        #expect(!FileManager.default.fileExists(atPath: world.plistPath))
    }

    @Test func plantedSymlinkIsReplacedNotFollowed() async throws {
        let world = try SetupWorld()
        let victim = world.root.appendingPathComponent("victim.txt")
        try Data("keep me".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(atPath: world.plistPath, withDestinationPath: victim.path)
        let error = await Self.outcome(world, .homebrew)
        #expect(error == nil)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me")
        #expect(world.plistAtInstall == ["HOMEBREW_PKG_USER": "alice"])
    }

    @Test func homebrewRefusedOnIntel() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .homebrew, host: HostInfo(appleSilicon: false, macOSMajor: 15))
        guard case .unsupportedHost = error else { Issue.record("expected unsupportedHost, got \(String(describing: error))"); return }
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func installerFailureCleansUp() async throws {
        let world = try SetupWorld()
        world.installerCode = 1
        let error = await Self.outcome(world, .homebrew)
        guard case .installFailed = error else { Issue.record("expected installFailed, got \(String(describing: error))"); return }
        #expect(!FileManager.default.fileExists(atPath: world.plistPath))
        #expect(world.leftovers.isEmpty)
    }

    // MARK: Refusals

    @Test func alreadyInstalledRefused() async throws {
        let world = try SetupWorld()
        world.markInstalled("/opt/homebrew/bin/brew")
        let error = await Self.outcome(world, .homebrew)
        guard case .alreadyInstalled = error else { Issue.record("expected alreadyInstalled, got \(String(describing: error))"); return }
        #expect(world.fetched.isEmpty)
        #expect(world.calls.isEmpty)
    }

    @Test func installedMeanwhileRefused() async throws {
        let world = try SetupWorld()
        world.installAfterDownload = "/opt/local/bin/port"
        let error = await Self.outcome(world, .macports)
        guard case .alreadyInstalled = error else { Issue.record("expected alreadyInstalled, got \(String(describing: error))"); return }
        #expect(world.commands("/usr/sbin/installer").isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func rootRequesterRefused() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .macports, uid: 0, user: "root")
        guard case .installFailed(let text) = error else { Issue.record("expected installFailed, got \(String(describing: error))"); return }
        #expect(text.contains("root"))
        #expect(world.fetched.isEmpty)
        #expect(world.calls.isEmpty)
    }

    // MARK: Download and verification

    @Test func digestMismatchDeletesFile() async throws {
        let world = try SetupWorld()
        world.downloadBytes = Data("someone else's installer".utf8)
        let error = await Self.outcome(world, .homebrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.commands("/usr/sbin/installer").isEmpty)
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func interruptedDownloadDeletesPartialFile() async throws {
        let world = try SetupWorld()
        world.downloadError = URLError(.networkConnectionLost)
        let error = await Self.outcome(world, .macports)
        guard case .network(let text) = error else { Issue.record("expected network, got \(String(describing: error))"); return }
        #expect(text.hasPrefix("BrewxPort couldn't reach GitHub to download MacPorts: "))
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func untrustedPkgNotInstalled() async throws {
        let world = try SetupWorld()
        world.spctlText = "MacPorts.pkg: rejected\nsource=Unnotarized Developer ID\n"
        let error = await Self.outcome(world, .macports)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.commands("/usr/sbin/installer").isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func hostileAssetNameRefused() async throws {
        let world = try SetupWorld()
        world.releaseJSON[.macports] = world.releaseJSON[.macports]!.replacingOccurrences(
            of: "\"name\":\"MacPorts-2.12.7-15-Sequoia.pkg\"", with: "\"name\":\"MacPorts-2.12.7/../../x-15-Sequoia.pkg\"")
        let error = await Self.outcome(world, .macports)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func networkFailureIsOneSentence() async throws {
        let world = try SetupWorld()
        world.fetchError = URLError(.notConnectedToInternet)
        let error = await Self.outcome(world, .homebrew)
        guard case .network(let text) = error else { Issue.record("expected network, got \(String(describing: error))"); return }
        #expect(text.hasPrefix("BrewxPort couldn't reach GitHub to download Homebrew: "))
        #expect(!text.contains("\n"))
        #expect(world.calls.isEmpty)
    }

    @Test(arguments: [403, 429]) func rateLimited(status: Int) async throws {
        let world = try SetupWorld()
        world.fetchError = HTTPStatusError(status: status)
        let error = await Self.outcome(world, .nanobrew)
        guard case .network(let text) = error else { Issue.record("expected network, got \(String(describing: error))"); return }
        #expect(text.lowercased().contains("try again in an hour"))
        #expect(world.calls.isEmpty)
    }

    @Test func macportsHappyPath() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .macports)
        #expect(error == nil)
        let install = try #require(world.commands("/usr/sbin/installer").first)
        #expect(install[2].hasSuffix("-MacPorts-2.12.7-15-Sequoia.pkg"))
        #expect(world.plistAtInstall == nil)
        #expect(world.leftovers.isEmpty)
        #expect(world.logs.contains("Downloading MacPorts v2.12.7…"))
    }

    // MARK: nanobrew

    static let rootCommands: Set<String> = ["/bin/mkdir", "/usr/sbin/chown", "/bin/mv", "/bin/chmod", "/bin/rm"]

    @Test func nanobrewUnpacksAsUser() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .nanobrew)
        #expect(error == nil)
        let calls = world.calls
        // Missing tree: three single-level creates, then non-recursive gives, deepest first.
        #expect(Array(calls.prefix(6)) == [
            ["mkdir(2)", "/opt/nanobrew"], ["mkdir(2)", "/opt/nanobrew/prefix"], ["mkdir(2)", "/opt/nanobrew/prefix/bin"],
            ["give", "/opt/nanobrew/prefix/bin", "502"], ["give", "/opt/nanobrew/prefix", "502"],
            ["give", "/opt/nanobrew", "502"],
        ])
        #expect(!calls.contains { Self.rootCommands.contains($0[0]) })
        // Everything after that runs as the user.
        for call in calls.dropFirst(6) {
            #expect(Array(call.prefix(3)) == ["/usr/bin/sudo", "-u", "#502"], "\(call)")
        }
        let tar = try #require(calls.first { $0.count > 3 && $0[3] == "/usr/bin/tar" })
        #expect(Array(tar.prefix(6)) == ["/usr/bin/sudo", "-u", "#502", "/usr/bin/tar", "--no-same-owner", "-xzf"])
        #expect(calls.contains { $0.contains("/bin/mv") && $0.last == "/opt/nanobrew/prefix/bin/nb" })
        #expect(calls.contains { $0.contains("/bin/chmod") && $0.last == "/opt/nanobrew/prefix/bin/nb" })
        #expect(calls.last.map { $0.contains("/bin/rm") } == true)
        #expect(world.downloadLimits["nb-arm64-apple-darwin.tar.gz"] == 1357781)
        #expect(world.leftovers.isEmpty)
    }

    @Test func nanobrewMakesOptWhenMissing() async throws {
        let world = try SetupWorld()
        world.optDir = .missing
        let error = await Self.outcome(world, .nanobrew)
        #expect(error == nil)
        #expect(world.calls.first == ["mkdir(2)", "/opt"])
        #expect(!world.calls.contains(["give", "/opt", "502"]))
    }

    @Test func nanobrewRequesterTreeTouchedOnlyAsRequester() async throws {
        let world = try SetupWorld()
        world.nanobrewDir = .directory(owner: 502)
        let error = await Self.outcome(world, .nanobrew)
        #expect(error == nil)
        let calls = world.calls
        #expect(!calls.contains { $0[0] == "mkdir(2)" || $0[0] == "give" || Self.rootCommands.contains($0[0]) })
        #expect(!calls.contains { $0.contains("-R") })
        #expect(calls.first == ["/usr/bin/sudo", "-u", "#502", "/bin/mkdir", "-p", "/opt/nanobrew/prefix/bin"])
        for call in calls { #expect(Array(call.prefix(3)) == ["/usr/bin/sudo", "-u", "#502"], "\(call)") }
    }

    @Test(arguments: [PathInfo.directory(owner: 0), .directory(owner: 777), .symlink, .file(owner: 502, mode: 0o644)])
    func nanobrewFolderNotTheRequestersRefused(existing: PathInfo) async throws {
        let world = try SetupWorld()
        world.nanobrewDir = existing
        let error = await Self.outcome(world, .nanobrew)
        guard case .installFailed(let text) = error else { Issue.record("expected installFailed, got \(String(describing: error))"); return }
        #expect(text.contains("/opt/nanobrew"))
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func nanobrewFailureRemovesCreatedFolders() async throws {
        let world = try SetupWorld()
        world.optDir = .missing
        world.failCommand = "/usr/bin/tar"
        let error = await Self.outcome(world, .nanobrew)
        guard case .installFailed = error else { Issue.record("expected installFailed, got \(String(describing: error))"); return }
        let tail = Array(world.calls.suffix(4))
        #expect(tail == [
            ["/usr/bin/sudo", "-u", "#502", "/bin/rmdir", "/opt/nanobrew/prefix/bin"],
            ["/usr/bin/sudo", "-u", "#502", "/bin/rmdir", "/opt/nanobrew/prefix"],
            ["rmdir(2)", "/opt/nanobrew"], ["rmdir(2)", "/opt"],
        ])
        #expect(!world.logs.contains { $0.contains("left") })
        #expect(world.leftovers.isEmpty)
    }

    @Test func nanobrewFailureLeavesNonEmptyFoldersAndSaysSo() async throws {
        let world = try SetupWorld()
        world.failCommand = "/bin/mv"
        world.rmdirSucceeds = false
        let error = await Self.outcome(world, .nanobrew)
        guard case .installFailed = error else { Issue.record("expected installFailed, got \(String(describing: error))"); return }
        #expect(world.logs.contains { $0.hasPrefix("BrewxPort left /opt/nanobrew/prefix/bin, /opt/nanobrew/prefix, /opt/nanobrew in place") })
    }

    @Test func nanobrewRequesterTreeNotRemovedOnFailure() async throws {
        let world = try SetupWorld()
        world.nanobrewDir = .directory(owner: 502)
        world.failCommand = "/usr/bin/tar"
        _ = await Self.outcome(world, .nanobrew)
        #expect(!world.calls.contains { $0.contains("/bin/rmdir") || $0[0] == "rmdir(2)" })
    }

    // MARK: nanobrew's published checksum file

    @Test func nanobrewChecksumFileAgrees() async throws {
        let world = try SetupWorld()
        world.sidecarText = SetupWorld.sha(world.payload).uppercased() + "  nb-arm64-apple-darwin.tar.gz\n"
        let error = await Self.outcome(world, .nanobrew)
        #expect(error == nil)
        #expect(world.downloadLimits["nb-arm64-apple-darwin.tar.gz.sha256"] == 4096)
    }

    @Test(arguments: [String(repeating: "0", count: 64) + "  nb-arm64-apple-darwin.tar.gz\n", "not a checksum\n", ""])
    func nanobrewChecksumFileDisagreesOrUnreadable(text: String) async throws {
        let world = try SetupWorld()
        world.sidecarText = text
        let error = await Self.outcome(world, .nanobrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func nanobrewChecksumFileMissing() async throws {
        let world = try SetupWorld()
        world.releaseJSON[.nanobrew] = try Self.removingAsset("nb-arm64-apple-darwin.tar.gz.sha256",
                                                              from: world.releaseJSON[.nanobrew]!)
        let error = await Self.outcome(world, .nanobrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func checksumFileParsing() {
        let hex = String(repeating: "ab", count: 32)
        #expect(EngineSetupRunner.checksum(fromSHA256File: "\(hex)  nb.tar.gz\n") == hex)
        #expect(EngineSetupRunner.checksum(fromSHA256File: "\n\t\(hex.uppercased())\n") == hex)
        #expect(EngineSetupRunner.checksum(fromSHA256File: String(hex.dropLast())) == nil)
        #expect(EngineSetupRunner.checksum(fromSHA256File: String(repeating: "g", count: 64)) == nil)
        #expect(EngineSetupRunner.checksum(fromSHA256File: "") == nil)
    }

    static func removingAsset(_ name: String, from json: String) throws -> String {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let assets = try #require(object["assets"] as? [[String: Any]])
        object["assets"] = assets.filter { ($0["name"] as? String) != name }
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: Exit codes, sizes, tags

    @Test func pkgutilFailureRefused() async throws {
        let world = try SetupWorld()
        world.pkgutilCode = 1
        let error = await Self.outcome(world, .homebrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.commands("/usr/sbin/installer").isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func spctlFailureRefusedEvenWithAcceptedText() async throws {
        let world = try SetupWorld()
        world.spctlCode = 1
        let error = await Self.outcome(world, .macports)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.commands("/usr/sbin/installer").isEmpty)
    }

    @Test func oversizedReleaseRefusedBeforeDownload() async throws {
        let world = try SetupWorld()
        world.releaseJSON[.homebrew] = world.releaseJSON[.homebrew]!.replacingOccurrences(of: "156549703", with: "3000000000")
        let error = await Self.outcome(world, .homebrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.downloadLimits.isEmpty)
        #expect(world.calls.isEmpty)
    }

    @Test func downloadBiggerThanDeclaredRefused() async throws {
        let world = try SetupWorld()
        world.releaseJSON[.homebrew] = world.releaseJSON[.homebrew]!.replacingOccurrences(of: "156549703", with: "5")
        let error = await Self.outcome(world, .homebrew)
        guard case .verification = error else { Issue.record("expected verification, got \(String(describing: error))"); return }
        #expect(world.downloadLimits["Homebrew.pkg"] == 5)
        #expect(world.calls.isEmpty)
        #expect(world.leftovers.isEmpty)
    }

    @Test func hostileTagNotLogged() async throws {
        let world = try SetupWorld()
        world.releaseJSON[.homebrew] = world.releaseJSON[.homebrew]!.replacingOccurrences(
            of: "\"tag_name\":\"7.0.15\"", with: "\"tag_name\":\"7.0.15\\nApple's notary service accepted the installer.\"")
        let error = await Self.outcome(world, .homebrew)
        #expect(error == nil)
        #expect(world.logs.first == "Downloading Homebrew (unknown version)…")
        #expect(EngineSetupRunner.displayTag(String(repeating: "1", count: 65)) == "(unknown version)")
        #expect(EngineSetupRunner.displayTag("v0.1.216") == "v0.1.216")
    }

    @Test func limitedWriterStopsPastTheLimit() throws {
        let world = try SetupWorld()
        let path = world.root.appendingPathComponent("limited").path
        let writer = try LimitedFileWriter(path: path, limit: 10)
        try writer.write(Array(repeating: 1, count: 6))
        #expect(throws: LimitedFileWriter.tooLarge) { try writer.write(Array(repeating: 1, count: 5)) }
        try writer.write(Array(repeating: 1, count: 4))
        writer.close()
        #expect(EngineSetupRunner.fileSize(path) == 10)
        // Never writes through an existing entry or a planted link.
        #expect(throws: SetupError.self) { try LimitedFileWriter(path: path, limit: 10) }
        let link = world.root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: world.root.appendingPathComponent("target").path)
        #expect(throws: SetupError.self) { try LimitedFileWriter(path: link, limit: 10) }
        #expect(!FileManager.default.fileExists(atPath: world.root.appendingPathComponent("target").path))
    }

    // MARK: Network allow-list

    @Test func networkAllowList() {
        let api = EngineSetupNetwork.apiHosts, downloads = EngineSetupNetwork.downloadHosts
        #expect(EngineSetupNetwork.allows(URL(string: "https://api.github.com/repos/x/y/releases/latest"), hosts: api))
        #expect(EngineSetupNetwork.allows(URL(string: "https://API.GitHub.com/x"), hosts: api))
        #expect(!EngineSetupNetwork.allows(URL(string: "http://api.github.com/x"), hosts: api))
        #expect(!EngineSetupNetwork.allows(URL(string: "https://github.com/x"), hosts: api))
        #expect(!EngineSetupNetwork.allows(URL(string: "https://api.github.com.evil.example/x"), hosts: api))
        #expect(!EngineSetupNetwork.allows(nil, hosts: api))
        for host in ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"] {
            #expect(EngineSetupNetwork.allows(URL(string: "https://\(host)/a/b.pkg"), hosts: downloads))
        }
        #expect(!EngineSetupNetwork.allows(URL(string: "https://api.github.com/x"), hosts: downloads))
        #expect(!EngineSetupNetwork.allows(URL(string: "https://evil.example/b.pkg"), hosts: downloads))
        #expect(!EngineSetupNetwork.allows(URL(string: "ftp://github.com/b.pkg"), hosts: downloads))
        #expect(!EngineSetupNetwork.allows(URL(string: "file:///etc/sudoers"), hosts: downloads))
    }

    @Test func finalResponseMustBeAllowedAnd200() throws {
        let hosts = EngineSetupNetwork.downloadHosts
        func response(_ url: String, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        try EngineSetupNetwork.check(response("https://github.com/a.pkg", 200), hosts: hosts, refused: false)
        #expect(throws: EngineSetupNetwork.unexpectedPlace) {
            try EngineSetupNetwork.check(response("https://evil.example/a.pkg", 200), hosts: hosts, refused: false)
        }
        #expect(throws: EngineSetupNetwork.unexpectedPlace) {
            try EngineSetupNetwork.check(response("https://github.com/a.pkg", 302), hosts: hosts, refused: true)
        }
        #expect(throws: HTTPStatusError(status: 404)) {
            try EngineSetupNetwork.check(response("https://github.com/a.pkg", 404), hosts: hosts, refused: false)
        }
    }

    // MARK: Administrators only

    @Test func setupNeedsAnAdministrator() {
        #expect(AdminMembership.setupRefusal(uid: 502, isAdmin: { $0 == 502 ? true : false }) == nil)
        #expect(AdminMembership.setupRefusal(uid: 503, isAdmin: { $0 == 502 ? true : false })
            == "Only an administrator can set up package managers.")
        #expect(AdminMembership.setupRefusal(uid: 502, isAdmin: { _ in nil })
            == "Only an administrator can set up package managers.")
    }

    @Test func membershipByUIDMatchesTheCurrentUserCheck() {
        #expect(AdminMembership.isAdmin(uid: getuid()) == AdminMembership.currentUserIsAdmin())
    }

    // MARK: Command Line Tools

    @Test func cltHappyPath() async throws {
        let world = try SetupWorld()
        let error = await Self.outcome(world, .commandLineTools)
        #expect(error == nil)
        #expect(world.placeholderSeenByList)
        #expect(world.calls == [
            ["/usr/sbin/softwareupdate", "-l"],
            ["/usr/sbin/softwareupdate", "-i", "Command Line Tools for Xcode-16.4"],
            ["/usr/bin/xcode-select", "--switch", "/Library/Developer/CommandLineTools"],
        ])
        #expect(world.fetched.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: world.placeholderPath))
    }

    @Test func cltNoLabel() async throws {
        let world = try SetupWorld()
        world.softwareUpdateList = "softwareupdate-list-none.txt"
        let error = await Self.outcome(world, .commandLineTools)
        #expect(error == .installFailed("Apple's Software Update didn't offer the Command Line Tools. Run xcode-select --install in Terminal, then click Check again."))
        #expect(world.commands("/usr/sbin/softwareupdate") == [["/usr/sbin/softwareupdate", "-l"]])
        #expect(!FileManager.default.fileExists(atPath: world.placeholderPath))
    }

    @Test func cltSoftwareUpdateListFailureStopsWithItsExitCode() async throws {
        let world = try SetupWorld()
        world.softwareUpdateCode = 1
        let error = await Self.outcome(world, .commandLineTools)
        #expect(error == .installFailed("Apple's Software Update couldn't be reached (exit 1)."))
        #expect(world.commands("/usr/sbin/softwareupdate") == [["/usr/sbin/softwareupdate", "-l"]])
        #expect(!FileManager.default.fileExists(atPath: world.placeholderPath))
    }

    // MARK: PATH note

    @Test func homebrewLogsThatItsInstallerAddedItToPath() async throws {
        let world = try SetupWorld()
        world.installerAlsoCreates = "/etc/paths.d/homebrew"
        #expect(await Self.outcome(world, .homebrew) == nil)
        #expect(world.logs.last == "Homebrew's installer added /opt/homebrew/bin to your PATH (/etc/paths.d/homebrew).")
    }

    @Test func homebrewLogsWhenItsInstallerLeftPathAlone() async throws {
        let world = try SetupWorld()
        #expect(await Self.outcome(world, .homebrew) == nil)
        #expect(world.logs.last == "Homebrew's installer didn't add itself to your PATH.")
    }

    @Test func macportsAndNanobrewLogWhatHappenedToPath() async throws {
        let ports = try SetupWorld()
        #expect(await Self.outcome(ports, .macports) == nil)
        #expect(ports.logs.last == "MacPorts' installer added /opt/local/bin to your shell's startup files.")
        let nano = try SetupWorld()
        #expect(await Self.outcome(nano, .nanobrew) == nil)
        #expect(nano.logs.last
                == "nanobrew isn't added to your PATH. BrewxPort finds it at /opt/nanobrew/prefix/bin/nb.")
    }

    @Test func aFailedSetupLogsNoPathNote() async throws {
        let world = try SetupWorld()
        world.installerCode = 1
        #expect(await Self.outcome(world, .homebrew) != nil)
        #expect(!world.logs.contains { $0.contains("PATH") })
    }

    @Test func cltAlreadyInstalledRefused() async throws {
        let world = try SetupWorld()
        world.markInstalled(CommandLineTools.marker)
        let error = await Self.outcome(world, .commandLineTools)
        guard case .alreadyInstalled = error else { Issue.record("expected alreadyInstalled, got \(String(describing: error))"); return }
        #expect(world.calls.isEmpty)
    }

    // MARK: Protocol

    @Test func unknownTargetIsNotASetupTarget() {
        #expect(SetupTarget(rawValue: "mas") == nil)
        #expect(SetupTarget(rawValue: "../homebrew") == nil)
    }

    @Test func interfacePinsTargetClass() {
        let sel = #selector(BrewxPortHelperProtocol.setUpEngine(authorization:target:reply:))
        let classes = HelperInterfaces.helper().classes(for: sel, argumentIndex: 1, ofReply: false)
        #expect(classes.count == 1)
        #expect(classes.contains(NSString.self as AnyObject as! AnyHashable))
    }
}
