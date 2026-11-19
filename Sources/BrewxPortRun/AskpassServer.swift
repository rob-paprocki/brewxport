import Foundation
import Security

public enum AskpassServerError: Error, Equatable {
    case askpassPathNotAbsolute
    /// `askpassPath` doesn't resolve to an existing file.
    case askpassNotFound
    case randomFailed(OSStatus)
    case socketPathTooLong
    /// `mkdir` or a system call on the socket failed with this errno.
    case system(call: String, errno: Int32)
    /// The socket directory isn't a real directory owned by us with mode 0700.
    case unsafeDirectory
    /// `peerRequirement` doesn't parse as a code-signing requirement.
    case badRequirement(OSStatus)
}

/// Hands the run's admin password to `brewxport-askpass` (sudo's `SUDO_ASKPASS`) over a private Unix socket.
///
/// sudo closes inherited descriptors and brew keeps only `HOMEBREW_*` variables, so the helper finds the socket
/// and a per-run nonce through `HOMEBREW_BREWXPORT_ASKPASS_SOCKET` and `HOMEBREW_BREWXPORT_ASKPASS_NONCE`. The password
/// itself never goes in the environment (spike `private/spikes/2026-11-sudo-askpass.md`).
///
/// The nonce alone can't gate the password: it sits in the environment of everything brew starts (formula Ruby,
/// build scripts, cask scripts), and any process of the same user can read another's environment. So the server
/// asks the kernel who is connecting (`AskpassPeer.inspect`: audit token, `LOCAL_PEERPID`, `proc_pidinfo`) and
/// answers only when the peer's uid is ours, its executable is `askpassPath` (both resolved with `realpath`), its
/// real parent is `/usr/bin/sudo`, and that sudo descends from this process (its kernel parent chain reaches
/// `getpid()` within `AskpassPeer.maxAncestorDepth` hops), so a sudo some other program started gets nothing even
/// if it found the nonce. A process that isn't brewxport-askpass run by a sudo BrewxPort started gets nothing.
///
/// With a `peerRequirement` (the app passes brewxport-askpass's identifier and the app's own team), the peer's code
/// signature is checked too: the kernel's audit token for the connection names the exact process, and
/// `SecCodeCheckValidity` must accept it against the requirement. A copy of brewxport-askpass that was modified, or
/// any binary at that path not signed by the same team, gets nothing (ruling R17).
///
/// Wire protocol: the client sends `nonce\n` (64 lowercase hex digits). The server checks the peer as above, then
/// the nonce in constant time (defense in depth), writes the password bytes and closes. Anything else is closed
/// with no bytes. Each parent pid (the kernel's, not one the client claims) is answered once, so a wrong password
/// fails on sudo's first attempt instead of three.
public final class AskpassServer: @unchecked Sendable {
    /// `SUDO_ASKPASS`, `HOMEBREW_BREWXPORT_ASKPASS_SOCKET` and `HOMEBREW_BREWXPORT_ASKPASS_NONCE`. Never the password.
    public let environment: [String: String]
    let socketPath: String
    private let core: Core

    /// `peerRequirement` is the code-signing requirement brewxport-askpass must satisfy. Nil skips the code check;
    /// only unit tests pass nil. A requirement that doesn't parse throws `.badRequirement`.
    public convenience init(secret: SecretBuffer, askpassPath: String, peerRequirement: String?) throws {
        try self.init(secret: secret, askpassPath: askpassPath, inspectPeer: AskpassPeer.inspect,
                      peerRequirement: peerRequirement)
    }

    /// `temporaryDirectory` is `$TMPDIR` in production. When `<it>/brewxport-<uuid>/askpass.sock` doesn't fit in
    /// `sun_path`, the directory goes under `/tmp` instead, with the same checks. `inspectPeer` is
    /// `AskpassPeer.inspect` and `parentOf` `AskpassPeer.parentPID(of:)` in production; tests pass a fake
    /// identity and process tree. `codeCheck` is `AskpassPeer.satisfies` in production and in the tests; it only
    /// runs when `peerRequirement` isn't nil. `owner` is `getpid()` in production; tests may pin a fake one so a
    /// fake process tree can't collide with the test runner's real pid.
    init(secret: SecretBuffer, askpassPath: String, temporaryDirectory: String = NSTemporaryDirectory(),
         inspectPeer: @escaping AskpassPeerInspector,
         parentOf: @escaping AskpassParentLookup = AskpassPeer.parentPID(of:),
         peerRequirement: String? = nil,
         codeCheck: @escaping AskpassCodeCheck = AskpassPeer.satisfies,
         owner: pid_t = getpid()) throws {
        guard askpassPath.hasPrefix("/") else { throw AskpassServerError.askpassPathNotAbsolute }
        guard let askpassRealPath = AskpassPeer.canonical(askpassPath) else {
            throw AskpassServerError.askpassNotFound
        }
        var peerCode: (@Sendable (Int32) -> Bool)?
        if let peerRequirement {
            var parsed: SecRequirement?
            let status = SecRequirementCreateWithString(peerRequirement as CFString, [], &parsed)
            guard status == errSecSuccess, let parsed else {
                throw AskpassServerError.badRequirement(status == errSecSuccess ? errSecCSReqInvalid : status)
            }
            let requirement = ParsedRequirement(value: parsed)
            peerCode = { client in codeCheck(client, requirement.value) }
        }
        let nonce = try Self.makeNonce()
        let (directory, socketPath) = try Self.choosePaths(temporaryDirectory: temporaryDirectory)
        try Self.makePrivateDirectory(directory)
        let core: Core
        do {
            core = try Core(secret: secret, nonce: Array(nonce.utf8), askpassRealPath: askpassRealPath,
                            inspectPeer: inspectPeer, parentOf: parentOf,
                            peerCode: peerCode, owner: owner,
                            directory: directory, socketPath: socketPath)
        } catch {
            rmdir(directory)
            throw error
        }
        self.core = core
        self.socketPath = socketPath
        environment = [
            "SUDO_ASKPASS": askpassPath,
            "HOMEBREW_BREWXPORT_ASKPASS_SOCKET": socketPath,
            "HOMEBREW_BREWXPORT_ASKPASS_NONCE": nonce,
        ]
        core.start()
    }

    /// Stops answering, closes the listener and removes the socket and its directory. Idempotent; deinit calls it.
    public func stop() { core.stop() }

    deinit { core.stop() }

    /// Parent pids answered so far, for tests.
    var answeredParents: Set<pid_t> { core.answeredParents }

    // MARK: Setup

    /// 32 random bytes, hex encoded.
    static func makeNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AskpassServerError.randomFailed(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)  // 104, including the NUL

    static func choosePaths(temporaryDirectory: String) throws -> (directory: String, socket: String) {
        func paths(in base: String) -> (String, String) {
            var base = base
            while base.count > 1, base.hasSuffix("/") { base.removeLast() }
            // The first 28 of the UUID's hex digits (dashes dropped), so the path under the standard 48-byte $TMPDIR
            // fits in sun_path (100 bytes; all 32 digits would make it 104, one byte too many).
            let directory = base + "/brewxport-"
                + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(28))
            return (directory, directory + "/askpass.sock")
        }
        for base in [temporaryDirectory, "/tmp"] where base.hasPrefix("/") {
            let (directory, socket) = paths(in: base)
            if socket.utf8.count < sunPathSize { return (directory, socket) }
        }
        throw AskpassServerError.socketPathTooLong
    }

    /// Creates `path` (never reusing one that exists), checks it's a real directory and ours, sets mode 0700
    /// (an unusual umask may have taken bits off), then checks the mode.
    static func makePrivateDirectory(_ path: String) throws {
        guard mkdir(path, 0o700) == 0 else { throw AskpassServerError.system(call: "mkdir", errno: errno) }
        func isOurDirectory(mode: mode_t?) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else { return false }
            return mode.map { st.st_mode & 0o7777 == $0 } ?? true
        }
        guard isOurDirectory(mode: nil), chmod(path, 0o700) == 0, isOurDirectory(mode: 0o700) else {
            rmdir(path)
            throw AskpassServerError.unsafeDirectory
        }
    }
}

/// A parsed requirement. `SecRequirement` is an immutable CF object, safe to share across threads.
private struct ParsedRequirement: @unchecked Sendable {
    let value: SecRequirement
}

// MARK: - Listener

/// The listening socket and its loop. A separate object so the loop's thread doesn't keep the server alive:
/// the server's deinit can then stop it.
private final class Core: @unchecked Sendable {
    static let requestLimit = 64 + 1   // nonce, \n
    static let clientTimeout: TimeInterval = 2

    private let secret: SecretBuffer
    private let nonce: [UInt8]
    private let askpassRealPath: String
    private let inspectPeer: AskpassPeerInspector
    private let parentOf: AskpassParentLookup
    /// The peer's code-signature check for one client socket, or nil to skip it.
    private let peerCode: (@Sendable (Int32) -> Bool)?
    /// The process every answered sudo must descend from: BrewxPort itself (`getpid()`), or a fake pid in tests.
    private let owner: pid_t
    private let directory: String
    private let socketPath: String
    private let listener: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var stopped = false
    private var started = false
    /// Parents already answered. Written on the loop thread, under `stateLock`.
    private var answered = Set<pid_t>()

    init(secret: SecretBuffer, nonce: [UInt8], askpassRealPath: String, inspectPeer: @escaping AskpassPeerInspector,
         parentOf: @escaping AskpassParentLookup, peerCode: (@Sendable (Int32) -> Bool)?, owner: pid_t,
         directory: String, socketPath: String) throws {
        self.secret = secret
        self.owner = owner
        self.nonce = nonce
        self.askpassRealPath = askpassRealPath
        self.inspectPeer = inspectPeer
        self.parentOf = parentOf
        self.peerCode = peerCode
        self.directory = directory
        self.socketPath = socketPath

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { throw AskpassServerError.system(call: "pipe", errno: errno) }
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        for fd in pipeFDs { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(wakeWrite, F_SETFL, fcntl(wakeWrite, F_GETFL) | O_NONBLOCK)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            close(wakeRead); close(wakeWrite)
            throw AskpassServerError.system(call: "socket", errno: err)
        }
        listener = fd
        do {
            try Self.check(fcntl(fd, F_SETFD, FD_CLOEXEC), "fcntl")
            try Self.check(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK), "fcntl")
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            guard pathBytes.count < AskpassServer.sunPathSize else { throw AskpassServerError.socketPathTooLong }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, byte) in pathBytes.enumerated() { raw[i] = byte }
            }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try Self.check(bound, "bind")
            try Self.check(chmod(socketPath, 0o600), "chmod")
            try Self.check(listen(fd, 16), "listen")
        } catch {
            close(fd); close(wakeRead); close(wakeWrite)
            unlink(socketPath)
            throw error
        }
    }

    private static func check(_ result: Int32, _ call: String) throws {
        if result < 0 { throw AskpassServerError.system(call: call, errno: errno) }
    }

    func start() {
        stateLock.withLock { started = true }
        let thread = Thread { [self] in loop() }
        thread.name = "com.brewxport.askpass"
        thread.start()
    }

    func stop() {
        let wasRunning: Bool = stateLock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard wasRunning else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
        if stateLock.withLock({ started }) {
            finished.wait()  // at most one client's timeout
        } else {
            close(listener)
        }
        close(wakeRead)
        close(wakeWrite)
        unlink(socketPath)
        rmdir(directory)
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    var answeredParents: Set<pid_t> { stateLock.withLock { answered } }

    private func loop() {
        defer {
            close(listener)
            finished.signal()
        }
        var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
        while !isStopped {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 || isStopped { return }
            guard fds[0].revents & Int16(POLLIN) != 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }  // EAGAIN, ECONNABORTED: try again
            handle(client)
            close(client)
        }
    }

    // MARK: One request

    private func handle(_ client: Int32) {
        // BSD hands accepted sockets the listener's O_NONBLOCK; timeouts only work on a blocking socket.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = Self.timeval(Self.clientTimeout)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), !secret.isWiped else { return }
        // Who is asking, from the kernel: brewxport-askpass itself, ours, run by a sudo that BrewxPort started.
        guard let peer = inspectPeer(client), peer.uid == getuid(),
              AskpassPeer.canonical(peer.path) == askpassRealPath,
              AskpassPeer.canonical(peer.parentPath) == AskpassPeer.sudoPath,
              AskpassPeer.chainReaches(owner, from: peer.parentPID, parentOf: parentOf)
        else { return }
        // And it's the brewxport-askpass we signed, checked on the process the kernel says is connected.
        if let peerCode, !peerCode(client) { return }
        guard let request = readRequest(client), Self.nonceMatches(request, nonce: nonce) else { return }
        let parent = peer.parentPID
        let first = stateLock.withLock { answered.insert(parent).inserted }
        guard first else { return }
        _ = secret.withUnwipedBytes { bytes in Self.writeAll(client, bytes) }
    }

    /// Reads until the first newline, the size cap, EOF or the deadline.
    private func readRequest(_ client: Int32) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(Self.clientTimeout)
        var request: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: Self.requestLimit + 1)
        while request.count <= Self.requestLimit {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var timeout = Self.timeval(remaining)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let want = Self.requestLimit + 1 - request.count
            let n = chunk.withUnsafeMutableBytes { read(client, $0.baseAddress, want) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            request.append(contentsOf: chunk[0..<n])
            if request.contains(0x0A) { break }
        }
        return request.count <= Self.requestLimit ? request : nil
    }

    /// `nonce\n` exactly, compared in constant time once the length matches.
    static func nonceMatches(_ request: [UInt8], nonce: [UInt8]) -> Bool {
        guard request.count == nonce.count + 1, request.last == 0x0A else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(request, nonce) { difference |= a ^ b }
        return difference == 0
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            offset += n
        }
    }

    private static func timeval(_ seconds: TimeInterval) -> Darwin.timeval {
        let seconds = max(seconds, 0.001)  // a zero timeval means "no timeout"
        let whole = Int(seconds)
        return Darwin.timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
    }
}
