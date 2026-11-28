import Testing
import Foundation
@testable import BrewxPortRun

/// The in-process side of the askpass wire protocol.
enum WireClient {
    enum Failure: Error { case socket, connect(Int32), pathTooLong }

    /// Connects, sends `payload`, then reads until the server closes, or until nothing has arrived for
    /// `receiveTimeout` seconds.
    static func send(_ payload: [UInt8], to path: String, closeWrite: Bool = true,
                     receiveTimeout: Int = 10) throws -> [UInt8] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw Failure.connect(errno) }
        if !payload.isEmpty {
            _ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        if closeWrite { shutdown(fd, SHUT_WR) }
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return out
    }

    static func request(nonce: String, to path: String) throws -> [UInt8] {
        try send(Array("\(nonce)\n".utf8), to: path)
    }
}

/// Runs blocking `work` on a thread of its own, so an async test that waits on a socket doesn't hold one of the few
/// threads Swift's concurrency pool has (three on a CI runner) while other tests need them.
func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}

/// A stand-in for the kernel's view of the peer, settable between requests.
final class FakePeer: @unchecked Sendable {
    static let askpassPath = "/usr/bin/true"   // any real file: the server resolves askpassPath at init

    private let lock = NSLock()
    private var _peer: AskpassPeer?
    init(_ peer: AskpassPeer? = FakePeer.valid()) { _peer = peer }

    var peer: AskpassPeer? {
        get { lock.withLock { _peer } }
        set { lock.withLock { _peer = newValue } }
    }

    /// Every fake pid in these tests is above macOS's PID_MAX (99_999), so none can be the test runner's own pid
    /// (or one of its ancestors) and make a fake process chain reach the server's owner by accident.
    static let fakeOwner: pid_t = 1_000_999

    static func valid(parent: pid_t = 1_000_001) -> AskpassPeer {
        AskpassPeer(uid: getuid(), pid: 1_000_000, path: askpassPath, parentPID: parent, parentPath: "/usr/bin/sudo")
    }

    var inspector: AskpassPeerInspector { { [self] _ in peer } }

    /// The fake sudo pids were all started by the test process.
    static let spawnedByUs: AskpassParentLookup = { pid in pid == getpid() ? nil : getpid() }
}

@Suite struct AskpassServerTests {
    static let password = "pa ss\u{00e9}word!"

    private func makeServer(_ password: String = AskpassServerTests.password, peer: FakePeer = FakePeer())
        throws -> (AskpassServer, SecretBuffer)
    {
        let secret = SecretBuffer(copying: Array(password.utf8))
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, inspectPeer: peer.inspector,
                                       parentOf: FakePeer.spawnedByUs)
        return (server, secret)
    }

    private func socketPath(_ server: AskpassServer) throws -> String {
        try #require(server.environment["HOMEBREW_BREWXPORT_ASKPASS_SOCKET"])
    }

    private func nonce(_ server: AskpassServer) throws -> String {
        try #require(server.environment["HOMEBREW_BREWXPORT_ASKPASS_NONCE"])
    }

    private func ask(_ server: AskpassServer) throws -> [UInt8] {
        try WireClient.request(nonce: nonce(server), to: socketPath(server))
    }

    // MARK: Setup and environment

    @Test func environmentHasExactlyTheThreeVariables() throws {
        let (server, _) = try makeServer()
        defer { server.stop() }
        let env = server.environment
        #expect(Set(env.keys) == ["SUDO_ASKPASS", "HOMEBREW_BREWXPORT_ASKPASS_SOCKET", "HOMEBREW_BREWXPORT_ASKPASS_NONCE"])
        #expect(env["SUDO_ASKPASS"] == FakePeer.askpassPath)
        let nonce = try nonce(server)
        #expect(nonce.count == 64)
        #expect(nonce.allSatisfy { "0123456789abcdef".contains($0) })
        let (other, _) = try makeServer()
        defer { other.stop() }
        #expect(other.environment["HOMEBREW_BREWXPORT_ASKPASS_NONCE"] != nonce)
        #expect(other.environment["HOMEBREW_BREWXPORT_ASKPASS_SOCKET"] != env["HOMEBREW_BREWXPORT_ASKPASS_SOCKET"])
    }

    @Test func relativeOrMissingAskpassPathIsRejected() {
        let secret = SecretBuffer(copying: Array("x".utf8))
        #expect(throws: AskpassServerError.askpassPathNotAbsolute) {
            _ = try AskpassServer(secret: secret, askpassPath: "brewxport-askpass", peerRequirement: nil)
        }
        #expect(throws: AskpassServerError.askpassNotFound) {
            _ = try AskpassServer(secret: secret, askpassPath: "/nonexistent/brewxport-askpass", peerRequirement: nil)
        }
    }

    @Test func environmentHasNoSecret() throws {
        let password = "a-long-admin-password-1234567890"
        let (server, _) = try makeServer(password)
        defer { server.stop() }
        for (key, value) in server.environment {
            #expect(!value.contains(password), "\(key) holds the secret")
            #expect(!key.contains(password))
            #expect(!value.contains(String(password.prefix(8))))
        }
    }

    @Test func socketDirIsPrivateAndOurs() throws {
        let (server, _) = try makeServer()
        defer { server.stop() }
        let path = try socketPath(server)
        #expect(path.utf8.count < 104)
        #expect(path.hasSuffix("/askpass.sock"))
        let dir = (path as NSString).deletingLastPathComponent
        #expect((dir as NSString).lastPathComponent.hasPrefix("brewxport-"))
        // A standard per-user TMPDIR (/var/folders/xx/<28>/T/) must be used, not the /tmp fallback.
        let tmp = NSTemporaryDirectory()
        if tmp.hasPrefix("/var/folders/"), tmp.utf8.count <= 49 {
            #expect(path.hasPrefix(tmp + "brewxport-"), "socket at \(path) (\(path.utf8.count) bytes)")
        }
        var st = stat()
        #expect(lstat(dir, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFDIR)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(st.st_uid == getuid())
        var sock = stat()
        #expect(lstat(path, &sock) == 0)
        #expect(sock.st_mode & S_IFMT == S_IFSOCK)
        #expect(sock.st_uid == getuid())
    }

    @Test func privateDirectoryIsForcedTo0700() throws {
        // Whatever the umask left, the directory ends up 0700; an existing path is never reused.
        let path = "/tmp/pt-\(UUID().uuidString.prefix(8))"
        try AskpassServer.makePrivateDirectory(path)
        defer { rmdir(path) }
        var st = stat()
        #expect(lstat(path, &st) == 0)
        #expect(st.st_mode & 0o7777 == 0o700)
        #expect(throws: AskpassServerError.system(call: "mkdir", errno: EEXIST)) {
            try AskpassServer.makePrivateDirectory(path)
        }
    }

    @Test func longTemporaryDirectoryFallsBackToTmp() throws {
        let long = NSTemporaryDirectory() + String(repeating: "d", count: 90)
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, temporaryDirectory: long,
                                       inspectPeer: FakePeer().inspector,
                                       parentOf: FakePeer.spawnedByUs)
        defer { server.stop() }
        let path = try socketPath(server)
        #expect(path.hasPrefix("/tmp/brewxport-"))
        #expect(path.utf8.count < 104)
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        #expect(lstat(dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
        #expect(st.st_uid == getuid())
        #expect(try ask(server) == Array("x".utf8))
    }

    @Test func shortTemporaryDirectoryIsUsedAsIs() throws {
        let base = "/tmp/pt-\(UUID().uuidString.prefix(8))"
        #expect(mkdir(base, 0o700) == 0)
        defer { rmdir(base) }
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath,
                                       temporaryDirectory: base + "/", inspectPeer: FakePeer().inspector,
                                       parentOf: FakePeer.spawnedByUs)
        defer { server.stop() }
        #expect(try socketPath(server).hasPrefix(base + "/brewxport-"))
    }

    // MARK: Who may ask

    @Test func serverReturnsSecretToCorrectNonce() throws {
        let (server, _) = try makeServer()
        defer { server.stop() }
        #expect(try ask(server) == Array(Self.password.utf8))
        #expect(server.answeredParents == [1_000_001])
    }

    @Test func wrongNonceRefused() throws {
        let peer = FakePeer()
        let (server, _) = try makeServer(peer: peer)
        defer { server.stop() }
        let path = try socketPath(server)
        let right = try nonce(server)
        var wrong = Array(right)
        wrong[63] = wrong[63] == "0" ? "1" : "0"
        for bad in [String(wrong), String(right.prefix(63)), right + "0", right.uppercased(), ""] {
            #expect(try WireClient.request(nonce: bad, to: path).isEmpty, "accepted \(bad)")
        }
        #expect(server.answeredParents.isEmpty)
    }

    @Test func wrongNonceThenRightNonceFromNewParentWorks() throws {
        let peer = FakePeer(FakePeer.valid(parent: 1_000_100))
        let (server, _) = try makeServer(peer: peer)
        defer { server.stop() }
        let path = try socketPath(server)
        let right = try nonce(server)
        #expect(try WireClient.request(nonce: String(repeating: "0", count: 64), to: path).isEmpty)
        peer.peer = FakePeer.valid(parent: 1_000_101)
        #expect(try WireClient.request(nonce: right, to: path) == Array(Self.password.utf8))
        // A wrong nonce doesn't use up the parent it came from.
        peer.peer = FakePeer.valid(parent: 1_000_100)
        #expect(try WireClient.request(nonce: right, to: path) == Array(Self.password.utf8))
    }

    @Test func secondCallFromSameParentRefused() throws {
        let peer = FakePeer(FakePeer.valid(parent: 1_000_200))
        let (server, _) = try makeServer(peer: peer)
        defer { server.stop() }
        #expect(try ask(server) == Array(Self.password.utf8))
        #expect(try ask(server).isEmpty)
        // A new askpass process under the same sudo is still the same parent.
        var again = FakePeer.valid(parent: 1_000_200)
        again.pid = 1_000_299
        peer.peer = again
        #expect(try ask(server).isEmpty)
        peer.peer = FakePeer.valid(parent: 1_000_201)
        #expect(try ask(server) == Array(Self.password.utf8))
        #expect(server.answeredParents == [1_000_200, 1_000_201])
    }

    @Test func peerThatIsNotAskpassRefused() throws {
        var other = FakePeer.valid()
        other.path = "/usr/bin/false"
        let (server, _) = try makeServer(peer: FakePeer(other))
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
    }

    @Test func parentThatIsNotSudoRefused() throws {
        for parentPath in ["/bin/zsh", "/opt/homebrew/bin/sudo", "/usr/bin/sudoedit", ""] {
            var peer = FakePeer.valid()
            peer.parentPath = parentPath
            let (server, _) = try makeServer(peer: FakePeer(peer))
            defer { server.stop() }
            #expect(try ask(server).isEmpty, "accepted parent \(parentPath)")
        }
    }

    @Test func peerOfAnotherUserRefused() throws {
        var peer = FakePeer.valid()
        peer.uid = getuid() == 0 ? 501 : 0
        let (server, _) = try makeServer(peer: FakePeer(peer))
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
    }

    @Test func unidentifiedPeerRefused() throws {
        let (server, _) = try makeServer(peer: FakePeer(nil))
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
    }

    @Test func askpassPathIsComparedAfterResolvingSymlinks() throws {
        let link = NSTemporaryDirectory() + "brewxport-askpass-link-\(UUID().uuidString.prefix(8))"
        #expect(symlink(FakePeer.askpassPath, link) == 0)
        defer { unlink(link) }
        let secret = SecretBuffer(copying: Array("x".utf8))
        // The kernel reports the real path; SUDO_ASKPASS keeps the path as given.
        let server = try AskpassServer(secret: secret, askpassPath: link, inspectPeer: FakePeer().inspector,
                                       parentOf: FakePeer.spawnedByUs)
        defer { server.stop() }
        #expect(server.environment["SUDO_ASKPASS"] == link)
        #expect(try ask(server) == Array("x".utf8))
    }

    @Test func inProcessClientRefusedWithRealInspector() throws {
        // The test process is neither brewxport-askpass nor a child of sudo, whatever it sends.
        let secret = SecretBuffer(copying: Array(Self.password.utf8))
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, peerRequirement: nil)
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
        #expect(try WireClient.send(Array("\(nonce(server))\n4242\n".utf8), to: socketPath(server)).isEmpty)
        #expect(server.answeredParents.isEmpty)
    }

    @Test func realInspectorReportsTheKernelsView() throws {
        let seen = LockedPeers()
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, inspectPeer: { fd in
            let peer = AskpassPeer.inspect(fd)
            seen.append(peer)
            return peer
        })
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
        let first = try #require(seen.all.first)
        let peer = try #require(first)
        #expect(peer.pid == getpid())
        #expect(peer.uid == getuid())
        #expect(peer.parentPID == getppid())
        let ownPath = try #require(Bundle.main.executablePath)
        #expect(AskpassPeer.canonical(peer.path) == AskpassPeer.canonical(ownPath))
        #expect(!peer.parentPath.isEmpty)
    }

    // MARK: The sudo must be one BrewxPort started

    @Test func sudoWhoseChainDoesNotReachUsIsRefused() throws {
        let secret = SecretBuffer(copying: Array("x".utf8))
        // 1_000_001 (the fake sudo) was started by launchd's child 1_000_500, not by the (fake) owner.
        let table: [pid_t: pid_t] = [1_000_001: 1_000_500, 1_000_500: 1]
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath,
                                       inspectPeer: FakePeer().inspector, parentOf: { table[$0] },
                                       owner: FakePeer.fakeOwner)
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
        #expect(server.answeredParents.isEmpty)
    }

    @Test func sudoStartedThroughBrewIsAnswered() throws {
        // BrewxPort -> brew -> ruby -> sudo: the chain reaches us in three hops.
        let secret = SecretBuffer(copying: Array("x".utf8))
        let owner = FakePeer.fakeOwner
        let table: [pid_t: pid_t] = [1_000_001: 1_000_600, 1_000_600: 1_000_601, 1_000_601: owner]
        let server = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath,
                                       inspectPeer: FakePeer().inspector, parentOf: { table[$0] }, owner: owner)
        defer { server.stop() }
        #expect(try ask(server) == Array("x".utf8))
    }

    @Test func chainWalkStopsAtLaunchdUnknownCyclesAndDepth() {
        let us: pid_t = 4242
        #expect(AskpassPeer.chainReaches(us, from: us) { _ in nil })                 // depth 0
        #expect(AskpassPeer.chainReaches(us, from: 10) { $0 == 10 ? us : nil })
        #expect(!AskpassPeer.chainReaches(us, from: 10) { _ in 1 })                  // up to launchd
        #expect(!AskpassPeer.chainReaches(us, from: 10) { _ in nil })                // pid gone
        #expect(!AskpassPeer.chainReaches(us, from: 10) { $0 == 10 ? 11 : 10 })      // cycle
        #expect(!AskpassPeer.chainReaches(us, from: 0) { _ in us })
        // A chain of exactly maxDepth hops reaches us; one more doesn't.
        let deep: AskpassParentLookup = { $0 > 100 ? $0 - 1 : nil }
        let limit = pid_t(AskpassPeer.maxAncestorDepth)
        #expect(AskpassPeer.chainReaches(101, from: 101 + limit, parentOf: deep))
        #expect(!AskpassPeer.chainReaches(101, from: 102 + limit, parentOf: deep))
    }

    @Test func parentLookupWorksOnRootProcesses() {
        // sudo runs as root. A user process can't read a root process's PROC_PIDTBSDINFO (EPERM), so the lookup
        // must use a flavor that works across users. launchd (pid 1, root) has parent 0.
        #expect(AskpassPeer.parentPID(of: 1) == 0)
    }

    @Test func realChainWalkFindsOurChild() throws {
        // A real child of this process reaches us; this process's own parent doesn't.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        #expect(AskpassPeer.chainReaches(getpid(), from: child.processIdentifier,
                                         parentOf: AskpassPeer.parentPID(of:)))
        #expect(!AskpassPeer.chainReaches(getpid(), from: getppid(), parentOf: AskpassPeer.parentPID(of:)))
    }

    // MARK: Request format, timing, lifecycle

    @Test func badlyFormedRequestsRefused() throws {
        let (server, _) = try makeServer()
        defer { server.stop() }
        let path = try socketPath(server)
        let n = try nonce(server)
        let bad: [String] = ["", "\n", n, "\(n)\n\n", "\(n)\n5\n", "\(n)\r\n", "\n\(n)\n", " \(n)\n", "\(n) \n"]
        for request in bad {
            #expect(try WireClient.send(Array(request.utf8), to: path).isEmpty, "accepted \(request.debugDescription)")
        }
        let huge = [UInt8](repeating: 0x61, count: 64 * 1024)
        #expect(try WireClient.send(huge, to: path).isEmpty)
        #expect(server.answeredParents.isEmpty)
        #expect(try ask(server) == Array(Self.password.utf8))
    }

    @Test func stalledClientDoesNotWedgeServer() async throws {
        let peer = FakePeer(FakePeer.valid(parent: 1_000_300))
        let (server, _) = try makeServer(peer: peer)
        defer { server.stop() }
        let path = try socketPath(server)
        let n = try nonce(server)
        // The stalled client waits up to 60 s for the server. A wedged server still holds it when the real request's
        // own 10 s receive timeout passes, so that request comes back empty and the password check fails.
        let stalled = Task {
            try await onOwnThread {
                try WireClient.send(Array(n.prefix(10).utf8), to: path, closeWrite: false, receiveTimeout: 60)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        #expect(try await onOwnThread { try WireClient.request(nonce: n, to: path) } == Array(Self.password.utf8))
        // Guards a slow drop: the 2 s client timeout, about 1.8 s after this request, not up to the request's 10 s;
        // CI took up to 3.4 s for the whole test.
        #expect(Date().timeIntervalSince(start) < 6)
        #expect(try await stalled.value.isEmpty)
    }

    @Test func wipedSecretRefusesEverything() throws {
        let (server, secret) = try makeServer()
        defer { server.stop() }
        secret.wipe()
        #expect(try ask(server).isEmpty)
    }

    @Test func stopRemovesSocket() throws {
        let (server, _) = try makeServer()
        let path = try socketPath(server)
        let dir = (path as NSString).deletingLastPathComponent
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: dir))
        server.stop()
    }

    @Test func stopThenConnectFails() throws {
        let (server, _) = try makeServer()
        let path = try socketPath(server)
        let n = try nonce(server)
        server.stop()
        #expect(throws: WireClient.Failure.self) { _ = try WireClient.request(nonce: n, to: path) }
    }

    @Test func deinitStops() throws {
        var path = ""
        do {
            let (server, _) = try makeServer()
            path = try socketPath(server)
            #expect(FileManager.default.fileExists(atPath: path))
        }
        #expect(!path.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }
}

/// The askpass peer's code-signature check (ruling R17). The fake inspector says the in-process client is a valid
/// brewxport-askpass run by sudo, so only the code check decides. The real check (`AskpassPeer.satisfies`) then runs
/// against the test process itself, through the connection's audit token.
@Suite struct AskpassCodeIdentityTests {
    static let unsatisfiable =
        "identifier \"com.brewxport.askpass\" and anchor apple generic and certificate leaf[subject.OU] = \"ZZZZZZZZZZ\""

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.withLock { count += 1 } }
        var calls: Int { lock.withLock { count } }
    }

    private func server(_ secret: SecretBuffer, peer: FakePeer = FakePeer(), requirement: String?,
                        codeCheck: @escaping AskpassCodeCheck = AskpassPeer.satisfies) throws -> AskpassServer {
        try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, inspectPeer: peer.inspector,
                          parentOf: FakePeer.spawnedByUs, peerRequirement: requirement, codeCheck: codeCheck)
    }

    private func ask(_ server: AskpassServer) throws -> [UInt8] {
        try WireClient.request(nonce: #require(server.environment["HOMEBREW_BREWXPORT_ASKPASS_NONCE"]),
                               to: #require(server.environment["HOMEBREW_BREWXPORT_ASKPASS_SOCKET"]))
    }

    /// This process's designated requirement, which the test process satisfies by definition.
    private func ownDesignatedRequirement() throws -> String {
        var code: SecCode?
        try #require(SecCodeCopySelf([], &code) == errSecSuccess)
        var staticCode: SecStaticCode?
        try #require(SecCodeCopyStaticCode(try #require(code), [], &staticCode) == errSecSuccess)
        var requirement: SecRequirement?
        try #require(SecCodeCopyDesignatedRequirement(try #require(staticCode), [], &requirement) == errSecSuccess)
        var text: CFString?
        try #require(SecRequirementCopyString(try #require(requirement), [], &text) == errSecSuccess)
        return try #require(text) as String
    }

    @Test func nilRequirementSkipsTheCodeCheck() throws {
        let counter = CallCounter()
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try server(secret, requirement: nil, codeCheck: { _, _ in counter.hit(); return false })
        defer { server.stop() }
        #expect(try ask(server) == Array("x".utf8))
        #expect(counter.calls == 0)
    }

    @Test func unsatisfiableRequirementRefuses() throws {
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try server(secret, requirement: Self.unsatisfiable)
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
        #expect(server.answeredParents.isEmpty)
    }

    @Test func satisfiedRequirementAnswers() throws {
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try server(secret, requirement: ownDesignatedRequirement())
        defer { server.stop() }
        #expect(try ask(server) == Array("x".utf8))
    }

    @Test func refusingCodeCheckRefusesAndRunsOnlyAfterThePeerChecks() throws {
        let counter = CallCounter()
        let secret = SecretBuffer(copying: Array("x".utf8))
        let peer = FakePeer(nil)
        let server = try server(secret, peer: peer, requirement: Self.unsatisfiable,
                                codeCheck: { _, _ in counter.hit(); return false })
        defer { server.stop() }
        #expect(try ask(server).isEmpty)
        #expect(counter.calls == 0)  // an unidentified peer never reaches the code check
        peer.peer = FakePeer.valid()
        #expect(try ask(server).isEmpty)
        #expect(counter.calls == 1)
        #expect(server.answeredParents.isEmpty)
    }

    @Test func unparsableRequirementThrows() {
        let secret = SecretBuffer(copying: Array("x".utf8))
        #expect(throws: AskpassServerError.self) {
            _ = try server(secret, requirement: "identifier \"unterminated")
        }
        #expect(throws: AskpassServerError.self) {
            _ = try AskpassServer(secret: secret, askpassPath: FakePeer.askpassPath, peerRequirement: "not a requirement (")
        }
    }

    @Test func requirementTextNamesIdentifierAndTeam() throws {
        let text = try #require(CodeIdentity.requirement(identifier: CodeIdentity.askpassIdentifier, team: "AB12CD34EF"))
        #expect(text == "identifier \"com.brewxport.askpass\" and anchor apple generic and certificate leaf[subject.OU] = \"AB12CD34EF\""
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]")
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        for bad in ["", "ab12cd34ef", "AB12CD34E", "AB12CD34EF1", "AB12\" or 1", "AB12CD34É1"] {
            #expect(CodeIdentity.requirement(identifier: "x", team: bad) == nil, "\(bad)")
        }
    }
}

final class LockedPeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [AskpassPeer?] = []
    func append(_ peer: AskpassPeer?) { lock.withLock { peers.append(peer) } }
    var all: [AskpassPeer?] { lock.withLock { peers } }
}

/// Runs the real `brewxport-askpass` binary with a near-empty environment and the test process as its parent.
@Suite struct BrewxPortAskpassEndToEndTests {
    static func binary() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("brewxport-askpass"))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/debug/brewxport-askpass"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private func run(_ executable: URL, arguments: [String] = ["Password:"],
                     environment: [String: String]) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments  // sudo passes its prompt; the client must ignore it
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    /// The askpass variables only, as brew's `env -i` would leave them.
    private func askpassEnvironment(_ server: AskpassServer) -> [String: String] {
        server.environment.filter { $0.key.hasPrefix("HOMEBREW_BREWXPORT_ASKPASS_") }
    }

    /// The real kernel view, except that the test process stands in for /usr/bin/sudo as the parent.
    private static func standInSudo(_ fd: Int32) -> AskpassPeer? {
        guard var peer = AskpassPeer.inspect(fd), peer.parentPID == getpid() else { return nil }
        peer.parentPath = AskpassPeer.sudoPath
        return peer
    }

    @Test func binaryRunByTheTestProcessIsRefused() throws {
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let secret = SecretBuffer(copying: Array(AskpassServerTests.password.utf8))
        let server = try AskpassServer(secret: secret, askpassPath: binary.path, peerRequirement: nil)
        defer { server.stop() }
        let result = try run(binary, environment: askpassEnvironment(server))
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(server.answeredParents.isEmpty)
    }

    @Test func binaryPrintsPasswordOnceThenRefusesSameParent() throws {
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let secret = SecretBuffer(copying: Array(AskpassServerTests.password.utf8))
        let server = try AskpassServer(secret: secret, askpassPath: binary.path, inspectPeer: Self.standInSudo)
        defer { server.stop() }
        let env = askpassEnvironment(server)

        let first = try run(binary, environment: env)
        #expect(first.status == 0)
        #expect(first.stdout == Data((AskpassServerTests.password + "\n").utf8))

        let second = try run(binary, environment: env)
        #expect(second.status == 1)
        #expect(second.stdout.isEmpty)
        #expect(server.answeredParents == [getpid()])
    }

    @Test func otherExecutableUnderTheSameParentIsRefused() throws {
        // The stand-in parent passes, but the peer isn't the binary named in SUDO_ASKPASS.
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: "/usr/bin/true", inspectPeer: Self.standInSudo)
        defer { server.stop() }
        let result = try run(binary, environment: askpassEnvironment(server))
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
    }

    @Test func binaryFailsQuietlyWithoutEnvironment() throws {
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let missing = try run(binary, environment: [:])
        #expect(missing.status == 1)
        #expect(missing.stdout.isEmpty)
        let bogus = try run(binary, environment: [
            "HOMEBREW_BREWXPORT_ASKPASS_SOCKET": "/tmp/brewxport-nonexistent/askpass.sock",
            "HOMEBREW_BREWXPORT_ASKPASS_NONCE": String(repeating: "a", count: 64),
        ])
        #expect(bogus.status == 1)
        #expect(bogus.stdout.isEmpty)
    }

    @Test func binaryWithWrongNonceExitsOne() throws {
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let secret = SecretBuffer(copying: Array("x".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: binary.path, inspectPeer: Self.standInSudo)
        defer { server.stop() }
        var env = askpassEnvironment(server)
        env["HOMEBREW_BREWXPORT_ASKPASS_NONCE"] = String(repeating: "0", count: 64)
        let result = try run(binary, environment: env)
        #expect(result.status == 1)
        #expect(result.stdout.isEmpty)
        #expect(server.answeredParents.isEmpty)
    }

    /// Real `/usr/bin/sudo -A -k` with a deliberately wrong password: sudo runs brewxport-askpass, the server answers
    /// once, sudo's retry is refused, and sudo fails fast. Costs one failed authentication in the system log, so
    /// it only runs with BREWXPORT_SUDO_E2E=1. The real-password path is Task 12's VM test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BREWXPORT_SUDO_E2E"] == "1"))
    func realSudoGetsOneAnswerThenFailsFast() throws {
        let binary = try #require(Self.binary(), "brewxport-askpass not built next to the test bundle")
        let secret = SecretBuffer(copying: Array("brewxport-deliberately-wrong-\(UUID().uuidString)".utf8))
        let server = try AskpassServer(secret: secret, askpassPath: binary.path, peerRequirement: nil)
        defer { server.stop() }
        var env = askpassEnvironment(server)
        env["SUDO_ASKPASS"] = binary.path
        env["PATH"] = "/usr/bin:/bin"
        let start = Date()
        let result = try run(URL(fileURLWithPath: "/usr/bin/sudo"), arguments: ["-A", "-k", "/usr/bin/true"],
                             environment: env)
        #expect(result.status != 0)
        #expect(server.answeredParents.count == 1)
        #expect(Date().timeIntervalSince(start) < 6)
    }
}
