import BrewxPortCore
import Foundation

/// A non-200 answer from GitHub. The live `fetch` and `download` throw it; 403 and 429 mean rate limiting.
public struct HTTPStatusError: Error, Equatable, Sendable {
    public let status: Int

    public init(status: Int) { self.status = status }
}

/// What `lstat` says about a path. Symlinks are reported, never followed.
public enum PathInfo: Equatable, Sendable {
    case missing
    case symlink
    case directory(owner: uid_t, mode: mode_t)
    case file(owner: uid_t, mode: mode_t)
    case other

    public static func lstat(_ path: String) -> PathInfo {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory(owner: info.st_uid, mode: info.st_mode & 0o7777)
        case S_IFREG: return .file(owner: info.st_uid, mode: info.st_mode & 0o7777)
        default: return .other
        }
    }
}

/// What reading one small text file found.
public enum FileRead: Equatable, Sendable {
    case text(String)
    /// Nothing to read: missing, not a plain file, outside the home folder, or too big.
    case skipped
    /// It's there, but reading it failed (for example a file still downloading from iCloud).
    case unreadable

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }
}

/// The helper's side of "set up a package manager". Runs as root. The caller supplies only the target and the
/// requester (from the XPC connection); the release, URL, checksum and paths are all worked out here.
///
/// Order: refuse if installed, fetch the latest release, pick the asset, download into the root-only folder,
/// check the SHA-256, check pkg signature and notarization, check again that nothing got installed meanwhile,
/// install, then confirm the engine is where BrewxPort looks for it. The download is deleted in every outcome.
public struct EngineSetupRunner: Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    /// Writes `from` to `to` (a new file), aborting once more than `maxBytes` arrive.
    public typealias Download = @Sendable (_ from: URL, _ to: URL, _ maxBytes: Int) async throws -> Void
    /// Absolute executable path and arguments; returns the exit code and stdout plus stderr.
    public typealias Run = @Sendable (String, [String]) async -> (Int32, String)

    public var fetch: Fetch
    public var download: Download
    public var run: Run
    public var exists: @Sendable (String) -> Bool
    public var inspect: @Sendable (String) -> PathInfo
    /// mkdir(2) of one level, root-owned 0755. Must create it: an existing entry is a failure.
    public var makeDirectory: @Sendable (String) -> Bool
    /// Hands one root-created directory to a uid without following a symlink (open O_NOFOLLOW + fchown), non-recursive.
    public var giveDirectory: @Sendable (String, uid_t) -> Bool
    /// rmdir(2): removes an empty directory only.
    public var removeDirectory: @Sendable (String) -> Bool
    public var host: HostInfo
    /// Root-owned 0700. Its parent must be root-owned and writable by root only; nanobrew's hand-off folder goes there.
    public var downloads: URL
    /// The requester's home folder, looked up from their uid (never from the helper's own environment).
    public var homeDirectory: @Sendable (uid_t) -> String?
    /// `name` directly in `home`: its text, skipped (missing, too big, or not a plain file inside `home`), or unreadable.
    public var readStartupFile: @Sendable (_ home: String, _ name: String) -> FileRead
    /// Every file in /etc/paths.d as (file name, what reading it found); nil if the folder couldn't be listed.
    public var readPathsD: @Sendable () -> [(String, FileRead)]?
    public var homebrewPlistPath: String
    public var cltPlaceholderPath: String
    #if DEBUG
    /// Test hook, compiled out of release builds: makes nanobrew's folder preparation fail right after this many
    /// folder steps (each `mkdir` and each hand-over counts as one), so a test can retry from every failure point.
    var failAfterNanobrewSteps: Int?
    #endif

    public static let defaultDownloads = URL(fileURLWithPath: "/Library/Application Support/BrewxPort/Downloads")
    static let opt = "/opt"
    static let nanobrewRoot = "/opt/nanobrew"
    static let nanobrewPrefix = "/opt/nanobrew/prefix"
    static let nanobrewBin = "/opt/nanobrew/prefix/bin"
    static let nanobrewBinary = EngineLocator.nanobrewPath
    static let cltFolder = "/Library/Developer/CommandLineTools"
    /// No installer BrewxPort sets up is anywhere near this; a release claiming more is refused.
    public static let maxDownloadBytes = 2 * 1024 * 1024 * 1024
    static let maxChecksumFileBytes = 4096

    public init(fetch: @escaping Fetch, download: @escaping Download, run: @escaping Run,
                exists: @escaping @Sendable (String) -> Bool,
                inspect: @escaping @Sendable (String) -> PathInfo = PathInfo.lstat,
                makeDirectory: @escaping @Sendable (String) -> Bool = RootDirectories.make,
                giveDirectory: @escaping @Sendable (String, uid_t) -> Bool = { RootDirectories.give($0, to: $1) },
                removeDirectory: @escaping @Sendable (String) -> Bool = RootDirectories.remove,
                host: HostInfo, downloads: URL = EngineSetupRunner.defaultDownloads,
                homeDirectory: @escaping @Sendable (uid_t) -> String? = EngineSetupRunner.homeDirectory,
                readStartupFile: @escaping @Sendable (String, String) -> FileRead = EngineSetupRunner.startupFile,
                readPathsD: @escaping @Sendable () -> [(String, FileRead)]? = EngineSetupRunner.readPathsD,
                homebrewPlistPath: String = HomebrewPkgUser.path,
                cltPlaceholderPath: String = CommandLineTools.placeholder) {
        self.fetch = fetch
        self.download = download
        self.run = run
        self.exists = exists
        self.inspect = inspect
        self.makeDirectory = makeDirectory
        self.giveDirectory = giveDirectory
        self.removeDirectory = removeDirectory
        self.host = host
        self.downloads = downloads
        self.homeDirectory = homeDirectory
        self.readStartupFile = readStartupFile
        self.readPathsD = readPathsD
        self.homebrewPlistPath = homebrewPlistPath
        self.cltPlaceholderPath = cltPlaceholderPath
    }

    /// Where each target is found once it's set up (the paths `EngineLocator` looks at).
    static func installedPath(_ target: SetupTarget) -> String {
        switch target {
        case .homebrew: return "/opt/homebrew/bin/brew"
        case .macports: return "/opt/local/bin/port"
        case .nanobrew: return nanobrewBinary
        case .commandLineTools: return CommandLineTools.marker
        }
    }

    static func name(_ target: SetupTarget) -> String {
        switch target {
        case .homebrew: return "Homebrew"
        case .macports: return "MacPorts"
        case .nanobrew: return "nanobrew"
        case .commandLineTools: return "the Command Line Tools"
        }
    }

    public func setUp(_ target: SetupTarget, forUID uid: uid_t, userName: String,
                      log: @Sendable (String) -> Void) async throws(SetupError) {
        let name = Self.name(target)
        guard uid != 0 else {
            throw .installFailed("BrewxPort won't set up \(name) for the root user. Sign in to your own administrator account and try again.")
        }
        guard !userName.isEmpty else {
            throw .installFailed("BrewxPort couldn't tell which user asked to set up \(name).")
        }
        try refuseIfInstalled(target)
        if target == .commandLineTools {
            try await setUpCommandLineTools(log: log)
            return
        }

        try Self.prepareDownloads(downloads)
        let release = try await latestRelease(target)
        let asset: ReleaseAsset
        do {
            asset = try GitHubRelease.asset(for: target, in: release, host: host)
        } catch let error as SetupError {
            throw error
        } catch {
            throw .noAsset("BrewxPort couldn't find \(name)'s download in the latest release.")
        }
        // The name goes into a path and into the first line of spctl's output, which the verdict reads.
        guard Self.isSafeFileName(asset.name) else {
            throw .verification("The latest \(name) release has a download with an unexpected name, so nothing was downloaded.")
        }

        guard asset.size > 0, asset.size <= Self.maxDownloadBytes else {
            throw .verification("The latest \(name) download is larger than BrewxPort accepts, so nothing was downloaded.")
        }

        let file = downloads.appendingPathComponent("\(UUID().uuidString)-\(asset.name)")
        // Registered before the download starts, so a partial file goes too.
        defer { try? FileManager.default.removeItem(at: file) }
        log("Downloading \(name) \(Self.displayTag(release.tag))…")
        do {
            try await download(asset.url, file, asset.size)
        } catch {
            throw Self.networkError(error, name: name)
        }
        try checkStillWanted()
        guard Self.fileSize(file.path) <= asset.size else {
            throw .verification("The \(name) download was bigger than GitHub said it would be, so it was deleted and nothing was installed.")
        }

        let digest: String
        do {
            digest = try EngineSetupTrust.sha256(of: file)
        } catch {
            throw .verification("BrewxPort couldn't read the \(name) download to check it.")
        }
        guard digest == asset.sha256 else {
            throw .verification("The \(name) download didn't match GitHub's checksum, so it was deleted and nothing was installed.")
        }
        if target == .nanobrew {
            try await checkPublishedChecksum(of: asset, in: release, digest: digest, name: name)
        }
        log("Checked the download against GitHub's checksum.")

        switch target {
        case .homebrew, .macports:
            try await verifyPackage(target, file: file)
            log("Apple's notary service accepted the installer.")
            try checkStillWanted()
            try refuseIfInstalled(target)
            log("Installing…")
            try await installPackage(target, file: file, userName: userName)
        case .nanobrew:
            try checkStillWanted()
            try refuseIfInstalled(target)
            log("Installing…")
            try await installNanobrew(archive: file, uid: uid, log: log)
        case .commandLineTools:
            break
        }
        log("\(name.prefix(1).uppercased() + name.dropFirst()) is set up.")
        if let note = pathNote(target, uid: uid) { log(note) }
    }

    /// One line saying what the install did about the shell's PATH.
    private func pathNote(_ target: SetupTarget, uid: uid_t) -> String? {
        switch target {
        case .homebrew:
            return exists("/etc/paths.d/homebrew")
                ? "Homebrew's installer added /opt/homebrew/bin to your PATH (/etc/paths.d/homebrew)."
                : "Homebrew's installer didn't add itself to your PATH."
        case .macports:
            switch macportsPathFile(uid: uid) {
            case .found(let file):
                return "MacPorts' installer added /opt/local/bin to your PATH (\(file))."
            case .notFound:
                return "MacPorts didn't add itself to your PATH. BrewxPort finds it at \(Self.installedPath(.macports)); to use port in Terminal, add /opt/local/bin to your PATH."
            case .couldNotCheck:
                return "BrewxPort couldn't check whether MacPorts is on your PATH. BrewxPort finds it at \(Self.installedPath(.macports)); to use port in Terminal, make sure /opt/local/bin is on your PATH."
            }
        case .nanobrew: return "nanobrew isn't added to your PATH. BrewxPort finds it at \(Self.nanobrewBinary)."
        case .commandLineTools: return nil
        }
    }

    static let macportsBin = "/opt/local/bin"
    static let startupFiles = [".zprofile", ".zshrc", ".bash_profile", ".profile"]
    static let maxStartupFileBytes = 64 * 1024

    /// Where MacPorts' bin folder is put on the PATH, if anywhere: one of the requester's shell startup files
    /// or an /etc/paths.d entry. The pkg runs as root, so this looks at what is on disk for the requester.
    /// A file that names it wins; otherwise anything that couldn't be read (or no home folder) means it couldn't check.
    private func macportsPathFile(uid: uid_t) -> PathSearch {
        var complete = true
        if let home = homeDirectory(uid) {
            for name in Self.startupFiles {
                switch readStartupFile(home, name) {
                case .text(let text): if Self.namesMacportsBin(text) { return .found("~/\(name)") }
                case .skipped: break
                case .unreadable: complete = false
                }
            }
        } else {
            complete = false
        }
        if let entries = readPathsD() {
            for (name, read) in entries {
                switch read {
                case .text(let text): if Self.namesMacportsBin(text) { return .found("/etc/paths.d/\(name)") }
                case .skipped: break
                case .unreadable: complete = false
                }
            }
        } else {
            complete = false
        }
        return complete ? .notFound : .couldNotCheck
    }

    private enum PathSearch {
        case found(String)
        case notFound
        case couldNotCheck
    }

    /// True if an uncommented line mentions `/opt/local/bin`.
    static func namesMacportsBin(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            return !trimmed.hasPrefix("#") && trimmed.contains(macportsBin)
        }
    }

    /// The requester's home folder from the user database (`getpwuid_r`), or nil if it has none or it isn't absolute.
    public static func homeDirectory(_ uid: uid_t) -> String? {
        guard let home = UserDatabase.entry(for: uid)?.home, home.hasPrefix("/") else { return nil }
        return home
    }

    /// Reads `home/name`, following links only while the real path stays inside the real home. Read-only; gives up
    /// on anything that isn't a regular file or is over `maxStartupFileBytes`. Nil for anything but text.
    public static func readStartupFile(home: String, name: String) -> String? {
        startupFile(home: home, name: name).text
    }

    /// `readStartupFile`, telling a file that isn't there (or doesn't count) apart from one that couldn't be read.
    public static func startupFile(home: String, name: String) -> FileRead {
        let realHome: String
        let real: String
        switch (realpath(home), realpath(home + "/" + name)) {
        case (.success(let h), .success(let r)): (realHome, real) = (h, r)
        case (.failure(.unreadable), _), (_, .failure(.unreadable)): return .unreadable
        default: return .skipped
        }
        guard real.hasPrefix(realHome.hasSuffix("/") ? realHome : realHome + "/") else { return .skipped }
        return readSmallFile(real)
    }

    /// Every entry in /etc/paths.d; empty if the folder isn't there, nil if it is but couldn't be listed.
    public static func readPathsD() -> [(String, FileRead)]? {
        let dir = "/etc/paths.d"
        if PathInfo.lstat(dir) == .missing { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return names.sorted().map { name in (name, readSmallFile(dir + "/" + name)) }
    }

    private enum Missing: Error { case skipped, unreadable }

    /// Errors that mean "nothing there to read", as opposed to "couldn't read it".
    private static func meansMissing(_ code: Int32) -> Bool {
        code == ENOENT || code == ENOTDIR || code == ELOOP
    }

    private static func realpath(_ path: String) -> Result<String, Missing> {
        guard let resolved = Darwin.realpath(path, nil) else {
            return .failure(meansMissing(errno) ? .skipped : .unreadable)
        }
        defer { free(resolved) }
        return .success(String(cString: resolved))
    }

    /// read(2), swappable in tests to simulate a read error.
    typealias ReadFD = @Sendable (_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int

    /// A regular file's text, opened without following a final link. Skipped if it isn't one or is too big;
    /// unreadable if opening or reading it fails. Plain POSIX calls only, so a read error can't raise.
    static func readSmallFile(_ path: String,
                              read: ReadFD = { fd, buffer, count in Darwin.read(fd, buffer, count) }) -> FileRead {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return meansMissing(errno) ? .skipped : .unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxStartupFileBytes else { return .skipped }
        // One byte over the limit, so a file that grew since fstat is caught.
        let capacity = maxStartupFileBytes + 1
        var bytes = [UInt8](repeating: 0, count: capacity)
        var filled = 0
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            while filled < capacity {
                let count = read(fd, buffer.baseAddress! + filled, capacity - filled)
                if count > 0 {
                    filled += min(count, capacity - filled)
                } else if count == 0 {
                    return true
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        guard ok else { return .unreadable }
        guard filled <= maxStartupFileBytes else { return .skipped }
        return .text(String(decoding: bytes[0..<filled], as: UTF8.self))
    }

    // MARK: Steps

    private func refuseIfInstalled(_ target: SetupTarget) throws(SetupError) {
        guard exists(Self.installedPath(target)) else { return }
        switch target {
        case .commandLineTools: throw .alreadyInstalled("The Command Line Tools are already installed.")
        default: throw .alreadyInstalled("\(Self.name(target)) is already set up on this Mac.")
        }
    }

    private func checkStillWanted() throws(SetupError) {
        if Task.isCancelled {
            throw .installFailed("The setup stopped because BrewxPort disconnected. Nothing was installed.")
        }
    }

    private func latestRelease(_ target: SetupTarget) async throws(SetupError) -> GitHubRelease {
        let name = Self.name(target)
        guard let repo = target.repo,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw .noAsset("\(name) doesn't come from GitHub.")
        }
        let data: Data
        do {
            data = try await fetch(url)
        } catch {
            throw Self.networkError(error, name: name)
        }
        do {
            return try GitHubRelease.decode(data)
        } catch {
            throw .verification("GitHub's information about the latest \(name) release didn't look right, so nothing was downloaded.")
        }
    }

    private func verifyPackage(_ target: SetupTarget, file: URL) async throws(SetupError) {
        let (pkgutilCode, pkgutil) = await run("/usr/sbin/pkgutil", ["--check-signature", file.path])
        guard pkgutilCode == 0 else {
            throw .verification("The \(Self.name(target)) installer's signature didn't check out (pkgutil exit code \(pkgutilCode)).")
        }
        let (spctlCode, spctl) = await run("/usr/sbin/spctl", ["-a", "-vvv", "-t", "install", file.path])
        guard spctlCode == 0 else {
            throw .verification("macOS did not accept the \(Self.name(target)) installer (spctl exit code \(spctlCode)).")
        }
        if let verdict = EngineSetupTrust.pkgVerdict(target: target, pkgutil: pkgutil, spctl: spctl) {
            throw verdict
        }
    }

    private func installPackage(_ target: SetupTarget, file: URL, userName: String) async throws(SetupError) {
        let name = Self.name(target)
        if target == .homebrew {
            // Homebrew's postinstall reads this to install for the requester, not whoever is at the console.
            defer { Self.removeEntry(homebrewPlistPath) }
            let plist: Data
            do {
                plist = try HomebrewPkgUser.plist(user: userName)
            } catch {
                throw .installFailed("BrewxPort couldn't prepare Homebrew's installer settings.")
            }
            try Self.writeRootOnly(plist, to: homebrewPlistPath)
            try await runInstaller(file: file, name: name)
        } else {
            try await runInstaller(file: file, name: name)
        }
        guard exists(Self.installedPath(target)) else {
            throw .installFailed("The installer finished, but \(name) isn't at \(Self.installedPath(target)).")
        }
    }

    private func runInstaller(file: URL, name: String) async throws(SetupError) {
        let (code, _) = await run("/usr/sbin/installer", ["-pkg", file.path, "-target", "/"])
        guard code == 0 else {
            throw .installFailed("Apple's installer couldn't install \(name) (exit code \(code)). The run log has its output.")
        }
    }

    /// nanobrew publishes `<asset>.sha256` beside each archive. It must exist and agree with both the API digest
    /// and the hash of what was downloaded.
    private func checkPublishedChecksum(of asset: ReleaseAsset, in release: GitHubRelease, digest: String,
                                        name: String) async throws(SetupError) {
        let sidecarName = asset.name + ".sha256"
        guard let sidecar = release.assets.first(where: { $0.name == sidecarName }),
              sidecar.size > 0, sidecar.size <= Self.maxChecksumFileBytes else {
            throw .verification("The \(name) release has no checksum file for its download, so nothing was installed.")
        }
        let file = downloads.appendingPathComponent("\(UUID().uuidString)-\(sidecarName)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await download(sidecar.url, file, Self.maxChecksumFileBytes)
        } catch {
            throw Self.networkError(error, name: name)
        }
        guard Self.fileSize(file.path) <= Self.maxChecksumFileBytes,
              let data = FileManager.default.contents(atPath: file.path),
              let published = Self.checksum(fromSHA256File: String(decoding: data, as: UTF8.self)) else {
            throw .verification("The \(name) checksum file couldn't be read, so nothing was installed.")
        }
        guard published == asset.sha256, published == digest else {
            throw .verification("The \(name) checksum file disagrees with GitHub's checksum, so nothing was installed.")
        }
    }

    /// The first whitespace-separated token of a `.sha256` file, if it is 64 hex digits (returned lowercase).
    static func checksum(fromSHA256File text: String) -> String? {
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.unicodeScalars.allSatisfy({ "0123456789abcdef".unicodeScalars.contains($0) }) else {
            return nil
        }
        return hex
    }

    /// Prepares `/opt/nanobrew/prefix/bin` for the requester without root ever writing into a tree they control.
    ///
    /// - Missing: root creates `/opt` (if missing), `/opt/nanobrew`, `prefix` and `bin` one level at a time with
    ///   mkdir(2), each of which must create its entry, all root-owned so nobody can swap them meanwhile. Then it
    ///   gives `bin`, `prefix` and `/opt/nanobrew` to the requester, deepest first, without following links and
    ///   without recursion (BSD `chown -R` would follow a planted hard link's target). An existing `/opt` must be
    ///   root's and writable by root only.
    /// - Already the requester's: root does nothing inside it; `mkdir -p` runs as the requester.
    /// - Anyone else's, root included: refused.
    ///
    /// After that everything inside runs as the requester: unpack (from a root-owned, world-readable hand-off copy;
    /// the downloads folder is root-only), move, mark executable, clean up. `nb init` is not run here. On failure,
    /// the folders created in this run are removed if they are empty (see `removeCreated`).
    private func installNanobrew(archive: URL, uid: uid_t, log: @Sendable (String) -> Void) async throws(SetupError) {
        let asUser = ["-u", "#\(uid)"]
        var created: [String] = []
        var handedOver: Set<String> = []
        switch inspect(Self.nanobrewRoot) {
        case .missing:
            switch inspect(Self.opt) {
            case .missing:
                guard makeDirectory(Self.opt) else {
                    throw .installFailed("BrewxPort couldn't create \(Self.opt).")
                }
                created.append(Self.opt)
            case .directory(let owner, let mode) where owner == 0:
                guard mode & 0o022 == 0 else {
                    throw .installFailed("\(Self.opt) is writable by other users, so BrewxPort won't set up nanobrew there.")
                }
            default:
                throw .installFailed("\(Self.opt) isn't a root-owned folder, so BrewxPort won't set up nanobrew in it.")
            }
            var failure: SetupError?
            var steps = 0
            do throws(SetupError) {
                for path in [Self.nanobrewRoot, Self.nanobrewPrefix, Self.nanobrewBin] {
                    guard makeDirectory(path) else { throw .installFailed("BrewxPort couldn't create \(path).") }
                    created.append(path)
                    steps += 1
                    try injectedFault(afterSteps: steps)
                }
                for path in [Self.nanobrewBin, Self.nanobrewPrefix, Self.nanobrewRoot] {
                    guard giveDirectory(path, uid) else {
                        throw .installFailed("BrewxPort couldn't give \(path) to your account.")
                    }
                    handedOver.insert(path)
                    steps += 1
                    try injectedFault(afterSteps: steps)
                }
            } catch {
                failure = error
            }
            if let failure {
                await removeCreated(created, handedOver: handedOver, uid: uid, log: log)
                throw failure
            }
        case .directory(let owner, _) where owner == uid:
            try await mustRun("/usr/bin/sudo", asUser + ["/bin/mkdir", "-p", Self.nanobrewBin],
                              "BrewxPort couldn't create \(Self.nanobrewBin)")
        default:
            throw .installFailed("\(Self.nanobrewRoot) already exists and isn't yours, so BrewxPort left it alone. Remove it or ask its owner, then try again.")
        }

        var failure: SetupError?
        do throws(SetupError) {
            try await unpackNanobrew(archive: archive, uid: uid)
        } catch {
            failure = error
        }
        if let failure {
            await removeCreated(created, handedOver: handedOver, uid: uid, log: log)
            throw failure
        }
    }

    /// The `failAfterNanobrewSteps` hook. In a release build it's an empty function the compiler drops.
    /// `afterSteps` counts this run's steps on nanobrew's own folders so far: three mkdirs, then three hand-overs.
    private func injectedFault(afterSteps steps: Int) throws(SetupError) {
        #if DEBUG
        if let limit = failAfterNanobrewSteps, steps >= limit {
            throw .installFailed("Injected failure after \(steps) nanobrew folder steps.")
        }
        #endif
    }

    private func unpackNanobrew(archive: URL, uid: uid_t) async throws(SetupError) {
        let handoff = downloads.deletingLastPathComponent().appendingPathComponent("Handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: handoff) }
        let readable = try Self.handOff(archive, into: handoff)

        let staging = "\(Self.nanobrewRoot)/.staging-\(UUID().uuidString)"
        let asUser = ["-u", "#\(uid)"]
        var failure: SetupError?
        do throws(SetupError) {
            try await mustRun("/usr/bin/sudo", asUser + ["/bin/mkdir", "-m", "0700", staging],
                              "BrewxPort couldn't make a folder to unpack nanobrew in")
            try await mustRun("/usr/bin/sudo", asUser + ["/usr/bin/tar", "--no-same-owner", "-xzf", readable.path,
                                                         "-C", staging, "nb"],
                              "BrewxPort couldn't unpack nanobrew")
            try await mustRun("/usr/bin/sudo", asUser + ["/bin/mv", "\(staging)/nb", Self.nanobrewBinary],
                              "BrewxPort couldn't move nb into place")
            try await mustRun("/usr/bin/sudo", asUser + ["/bin/chmod", "0755", Self.nanobrewBinary],
                              "BrewxPort couldn't make nb executable")
        } catch {
            failure = error
        }
        _ = await run("/usr/bin/sudo", asUser + ["/bin/rm", "-rf", staging])
        if let failure { throw failure }

        guard case .file(let owner, let mode) = inspect(Self.nanobrewBinary), owner == uid, mode & 0o111 != 0 else {
            throw .installFailed("nanobrew was unpacked, but \(Self.nanobrewBinary) isn't an executable file.")
        }
    }

    /// Removes the folders created for nanobrew in this run, deepest first, only while empty; nothing that was there
    /// before. Who removes each one depends on its parent. A parent already handed to the requester could hold a
    /// link they swapped in, so the entry is removed as the requester. A parent root still holds (not handed over
    /// yet, or the root-owned `/opt` or `/`) can't have been changed by anyone else, so root removes the entry with
    /// rmdir(2); the requester couldn't, and a root-owned `/opt/nanobrew` left behind would block the next try.
    private func removeCreated(_ created: [String], handedOver: Set<String>, uid: uid_t,
                               log: @Sendable (String) -> Void) async {
        var left: [String] = []
        for path in created.reversed() {
            let parent = (path as NSString).deletingLastPathComponent
            let removed: Bool
            if handedOver.contains(parent) {
                removed = await run("/usr/bin/sudo", ["-u", "#\(uid)", "/bin/rmdir", path]).0 == 0
            } else {
                removed = removeDirectory(path)
            }
            if !removed { left.append(path) }
        }
        if !left.isEmpty {
            log("BrewxPort left \(left.joined(separator: ", ")) in place because it isn't empty.")
        }
    }

    private func setUpCommandLineTools(log: @Sendable (String) -> Void) async throws(SetupError) {
        // The placeholder makes Software Update list the Command Line Tools. It goes in every outcome.
        defer { Self.removeEntry(cltPlaceholderPath) }
        try Self.writeRootOnly(Data(), to: cltPlaceholderPath)
        log("Asking Apple's Software Update for the Command Line Tools…")
        let (listCode, list) = await run("/usr/sbin/softwareupdate", ["-l"])
        guard listCode == 0 else {
            throw .installFailed("Apple's Software Update couldn't be reached (exit \(listCode)).")
        }
        guard let label = CommandLineTools.label(fromSoftwareUpdateList: list) else {
            throw .installFailed("Apple's Software Update didn't offer the Command Line Tools. Run xcode-select --install in Terminal, then click Check again.")
        }
        try checkStillWanted()
        log("Installing \(label)…")
        try await mustRun("/usr/sbin/softwareupdate", ["-i", label], "Software Update couldn't install \(label)")
        try await mustRun("/usr/bin/xcode-select", ["--switch", Self.cltFolder],
                          "xcode-select couldn't switch to the Command Line Tools")
        guard exists(CommandLineTools.marker) else {
            throw .installFailed("Software Update finished, but the Command Line Tools aren't in \(Self.cltFolder).")
        }
        log("The Command Line Tools are set up.")
    }

    private func mustRun(_ path: String, _ arguments: [String], _ failure: String) async throws(SetupError) {
        let (code, _) = await run(path, arguments)
        guard code == 0 else { throw .installFailed("\(failure) (exit code \(code)).") }
    }

    // MARK: Errors

    static func networkError(_ error: any Error, name: String) -> SetupError {
        switch error {
        case let error as SetupError:
            return error
        case let error as HTTPStatusError where error.status == 403 || error.status == 429:
            return .network("GitHub's download limit was reached. Try again in an hour.")
        case let error as HTTPStatusError:
            return .network("GitHub answered with an error (HTTP \(error.status)) when BrewxPort asked for \(name).")
        case is CancellationError:
            return .installFailed("The setup stopped because BrewxPort disconnected. Nothing was installed.")
        case let error as URLError where error.code == .cancelled:
            return .installFailed("The setup stopped because BrewxPort disconnected. Nothing was installed.")
        case let error as URLError:
            let detail = plainWords(error.code).map { ": \($0)" } ?? ""
            return .network("BrewxPort couldn't reach GitHub to download \(name)\(detail).")
        default:
            return .network("BrewxPort couldn't download \(name): \(oneLine(error.localizedDescription))")
        }
    }

    /// The common reasons a connection fails, in plain words. Anything else gets no detail rather than URLSession's
    /// own text ("bad URL" for a blocked host).
    private static func plainWords(_ code: URLError.Code) -> String? {
        switch code {
        case .notConnectedToInternet: return "no internet connection"
        case .timedOut: return "the connection timed out"
        case .cannotFindHost, .dnsLookupFailed: return "couldn't find the server"
        case .networkConnectionLost: return "the connection dropped"
        default: return nil
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    // MARK: Files (root-side, never following a planted link)

    /// The release tag for a log line: the safe file-name characters only, at most 64 of them.
    static func displayTag(_ tag: String) -> String {
        tag.count <= 64 && isSafeFileName(tag) ? tag : "(unknown version)"
    }

    /// lstat size; `Int.max` when missing, so a size check fails closed.
    static func fileSize(_ path: String) -> Int {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return Int.max }
        return Int(info.st_size)
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    /// Makes the downloads folder's parent (0755) and the folder (0700). As root both must be real directories owned
    /// by root; anything else is refused rather than repaired.
    static func prepareDownloads(_ downloads: URL) throws(SetupError) {
        try ensureDirectory(downloads.deletingLastPathComponent().path, mode: 0o755)
        try ensureDirectory(downloads.path, mode: 0o700)
    }

    private static func ensureDirectory(_ path: String, mode: mode_t) throws(SetupError) {
        if mkdir(path, mode) != 0, errno != EEXIST {
            throw .installFailed("BrewxPort couldn't create \(path): \(String(cString: strerror(errno))).")
        }
        try secureDirectory(path, mode: mode)
    }

    /// Opens `path` as a directory without following a symlink, refuses it unless root owns it (when running as
    /// root), then sets root:wheel and `mode` through the descriptor, so a path swapped meanwhile can't redirect it.
    private static func secureDirectory(_ path: String, mode: mode_t) throws(SetupError) {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw .installFailed("\(path) isn't a plain folder, so BrewxPort won't use it.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw .installFailed("BrewxPort couldn't check \(path).")
        }
        if geteuid() == 0 {
            guard info.st_uid == 0 else {
                throw .installFailed("\(path) isn't owned by root, so BrewxPort won't use it.")
            }
            // A new folder takes its parent's group (admin under /Library/Application Support); make it wheel.
            guard fchown(fd, 0, 0) == 0 else {
                throw .installFailed("BrewxPort couldn't make \(path) root:wheel.")
            }
        }
        guard fchmod(fd, mode) == 0 else {
            throw .installFailed("BrewxPort couldn't set the permissions of \(path).")
        }
    }

    /// A fresh folder (0755 once filled) holding a 0644 copy of `file`, so the requester can read it but not change it.
    private static func handOff(_ file: URL, into folder: URL) throws(SetupError) -> URL {
        guard mkdir(folder.path, 0o700) == 0 else {
            throw .installFailed("BrewxPort couldn't prepare nanobrew for unpacking.")
        }
        let copy = folder.appendingPathComponent("nb.tar.gz")
        do {
            try FileManager.default.copyItem(at: file, to: copy)
        } catch {
            throw .installFailed("BrewxPort couldn't prepare nanobrew for unpacking.")
        }
        guard chmod(copy.path, 0o644) == 0 else {
            throw .installFailed("BrewxPort couldn't prepare nanobrew for unpacking.")
        }
        try secureDirectory(folder.path, mode: 0o755)
        return copy
    }

    /// Removes whatever is at `path` (a planted symlink included, never its target), then creates a new file there
    /// with `O_EXCL | O_NOFOLLOW`, mode 0600, owned by root:wheel when running as root. If someone recreates the
    /// path in between, the create fails instead of writing through their file.
    static func writeRootOnly(_ data: Data, to path: String) throws(SetupError) {
        removeEntry(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw .installFailed("BrewxPort couldn't write \(path): \(String(cString: strerror(errno))).")
        }
        defer { close(fd) }
        if geteuid() == 0, fchown(fd, 0, 0) != 0 {
            throw .installFailed("BrewxPort couldn't make \(path) root-owned.")
        }
        guard fchmod(fd, 0o600) == 0 else {
            throw .installFailed("BrewxPort couldn't set the permissions of \(path).")
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard written else { throw .installFailed("BrewxPort couldn't write \(path).") }
    }

    /// `unlink`, which removes a symlink itself. A directory at `path` stays (and `writeRootOnly` then fails).
    static func removeEntry(_ path: String) {
        _ = unlink(path)
    }
}

// MARK: Live

extension EngineSetupRunner {
    /// The helper's runner: URLSession for GitHub, `ProcessRunner` for commands (output forwarded line by line).
    public static func live(onOutput: @escaping @Sendable (OutputEvent) -> Void) -> EngineSetupRunner {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds(BrewxPortTimeouts.releaseQuery)
        configuration.timeoutIntervalForResource = seconds(BrewxPortTimeouts.engineSetup)
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]

        return EngineSetupRunner(
            fetch: { url in
                guard EngineSetupNetwork.allows(url, hosts: EngineSetupNetwork.apiHosts) else {
                    throw EngineSetupNetwork.unexpectedPlace
                }
                var request = URLRequest(url: url, timeoutInterval: seconds(BrewxPortTimeouts.releaseQuery))
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
                let guardian = RedirectGuard(hosts: EngineSetupNetwork.apiHosts)
                let data: Data, response: URLResponse
                do {
                    (data, response) = try await session.data(for: request, delegate: guardian)
                } catch {
                    throw guardian.refused ? EngineSetupNetwork.unexpectedPlace : error
                }
                try EngineSetupNetwork.check(response, hosts: EngineSetupNetwork.apiHosts, refused: guardian.refused)
                return data
            },
            download: { url, destination, maxBytes in
                guard EngineSetupNetwork.allows(url, hosts: EngineSetupNetwork.downloadHosts) else {
                    throw EngineSetupNetwork.unexpectedPlace
                }
                let request = URLRequest(url: url, timeoutInterval: seconds(BrewxPortTimeouts.releaseQuery))
                let guardian = RedirectGuard(hosts: EngineSetupNetwork.downloadHosts)
                let bytes: URLSession.AsyncBytes, response: URLResponse
                do {
                    (bytes, response) = try await session.bytes(for: request, delegate: guardian)
                } catch {
                    throw guardian.refused ? EngineSetupNetwork.unexpectedPlace : error
                }
                try EngineSetupNetwork.check(response, hosts: EngineSetupNetwork.downloadHosts, refused: guardian.refused)
                if response.expectedContentLength > Int64(maxBytes) { throw LimitedFileWriter.tooLarge }
                // Streamed into a new file, stopping as soon as more than the release declared arrives.
                let writer = try LimitedFileWriter(path: destination.path, limit: maxBytes)
                defer { writer.close() }
                var buffer: [UInt8] = []
                buffer.reserveCapacity(1 << 20)
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count == 1 << 20 {
                        try writer.write(buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                try writer.write(buffer)
            },
            run: { path, arguments in
                // Unstructured on purpose: a disconnect must not kill `installer` or `softwareupdate` halfway. The
                // runner stops between steps instead.
                await Task {
                    let lines = LineCollector()
                    let options = RunOptions(environment: environment, timeout: BrewxPortTimeouts.engineSetup,
                                             workingDirectory: "/")
                    do {
                        let code = try await ProcessRunner(environment: environment).stream(
                            URL(fileURLWithPath: path), arguments, options: options
                        ) { event in
                            lines.add(event)
                            onOutput(event)
                        }
                        return (code, lines.text)
                    } catch CommandRunnerError.timedOut(let limit) {
                        return (-1, "\(path) \(BrewxPortTimeouts.didntAnswer(within: limit))")
                    } catch {
                        return (-1, "Couldn't run \(path): \(error)")
                    }
                }.value
            },
            exists: { FileManager.default.fileExists(atPath: $0) },
            host: .current())
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Collects a command's stdout and stderr lines in arrival order.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ event: OutputEvent) {
        lock.withLock {
            switch event {
            case .stdout(let line), .stderr(let line): lines.append(line)
            }
        }
    }

    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

/// Where setup's network traffic may go: HTTPS to GitHub only, checked on the first URL, every redirect and the
/// final response.
public enum EngineSetupNetwork {
    public static let apiHosts: Set<String> = ["api.github.com"]
    public static let downloadHosts: Set<String> = GitHubRelease.allowedHosts

    static let unexpectedPlace = SetupError.verification(
        "GitHub sent BrewxPort somewhere other than GitHub, so nothing was downloaded.")

    public static func allows(_ url: URL?, hosts: Set<String>) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// The final response must come from an allowed host, no redirect may have been refused, and the status is 200.
    static func check(_ response: URLResponse, hosts: Set<String>, refused: Bool) throws {
        guard !refused, allows(response.url, hosts: hosts) else { throw unexpectedPlace }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw HTTPStatusError(status: status) }
    }
}

/// Follows a redirect only to an allowed host over HTTPS; anything else cancels the task.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let hosts: Set<String>
    private let lock = NSLock()
    private var _refused = false

    init(hosts: Set<String>) { self.hosts = hosts }

    var refused: Bool { lock.withLock { _refused } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        if EngineSetupNetwork.allows(request.url, hosts: hosts) { return request }
        lock.withLock { _refused = true }
        task.cancel()
        return nil
    }
}

/// Writes a new file (`O_EXCL | O_NOFOLLOW`, 0600) and throws once more than `limit` bytes are offered.
final class LimitedFileWriter {
    static let tooLarge = SetupError.verification(
        "The download was bigger than GitHub said it would be, so BrewxPort stopped it.")

    private let fd: Int32
    private let limit: Int
    private(set) var written = 0

    init(path: String, limit: Int) throws {
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SetupError.installFailed("BrewxPort couldn't save the download: \(String(cString: strerror(errno))).")
        }
        self.limit = limit
    }

    func write(_ bytes: [UInt8]) throws {
        guard written + bytes.count <= limit else { throw Self.tooLarge }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw SetupError.installFailed("BrewxPort couldn't save the download.")
                }
                offset += count
            }
        }
        written += bytes.count
    }

    func close() { _ = Darwin.close(fd) }
}

/// Root's directory operations for nanobrew's folders: one level at a time, never through a symlink.
public enum RootDirectories {
    /// mkdir(2) 0755 that must create the entry, then root:wheel 0755 through a no-follow descriptor. When that
    /// fails after the mkdir, the new entry is rmdir'd (non-recursive, doesn't follow a final link), so it isn't left
    /// behind to block the next try.
    @Sendable public static func make(_ path: String) -> Bool {
        guard mkdir(path, 0o755) == 0 else { return false }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            rmdir(path)
            return false
        }
        let done = fchown(fd, 0, 0) == 0 && fchmod(fd, 0o755) == 0
        close(fd)
        if !done { rmdir(path) }
        return done
    }

    /// Gives a root-owned directory (just made by `make`) to `uid`, non-recursively, without following a symlink.
    @Sendable public static func give(_ path: String, to uid: uid_t) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0 else { return false }
        return fchown(fd, uid, gid_t.max) == 0
    }

    @Sendable public static func remove(_ path: String) -> Bool { rmdir(path) == 0 }
}
