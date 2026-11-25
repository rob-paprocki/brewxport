import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortRun

enum Steps {
    static let portPath = "/opt/local/bin/port"
    static let brewPath = "/opt/homebrew/bin/brew"
    static let intelBrewPath = "/usr/local/bin/brew"
    static let nbPath = "/opt/nanobrew/prefix/bin/nb"
    static let masPath = "/opt/homebrew/bin/mas"

    static func port(_ name: String = "wget") -> RunStep {
        RunStep(engine: .macports, kind: .port,
                operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: portPath), arguments: ["-N", "upgrade", name],
                                  needsRoot: true),
                title: "Upgrade \(name)")
    }

    static func cask(_ name: String = "blackhole-2ch", brew: String = brewPath, arch: Arch? = nil) -> RunStep {
        RunStep(engine: .homebrew, kind: .cask,
                operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: brew), arguments: ["upgrade", "--cask", name],
                                  needsRoot: false, arch: arch),
                title: "Upgrade \(name)")
    }

    static func formula(_ name: String = "wget", brew: String = brewPath, arch: Arch? = nil) -> RunStep {
        RunStep(engine: .homebrew,
                operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: brew), arguments: ["upgrade", name],
                                  needsRoot: false, arch: arch),
                title: "Upgrade \(name)")
    }

    static func nanobrew(_ name: String = "jq") -> RunStep {
        RunStep(engine: .nanobrew, kind: .formula,
                operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: nbPath), arguments: ["upgrade", name],
                                  needsRoot: false),
                title: "Upgrade \(name)")
    }

    static func mas(_ id: String = "497799835", needsRoot: Bool = true) -> RunStep {
        RunStep(engine: .mas, kind: .app,
                operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: masPath), arguments: ["upgrade", id],
                                  needsRoot: needsRoot),
                title: "Upgrade \(id)")
    }

    static func setup(_ target: SetupTarget = .macports) -> RunStep {
        RunStep(engine: .macports, kind: .port, operation: .install,
                spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], needsRoot: true),
                title: "Set up \(target.rawValue)", setupTarget: target)
    }

    static func nbInit() -> RunStep {
        RunStep(engine: .nanobrew, kind: .formula, operation: .install,
                spec: CommandSpec(executable: URL(fileURLWithPath: nbPath), arguments: ["init"], needsRoot: true),
                title: "Run nb init", dependsOnPrevious: true)
    }

    static func remove(_ name: String = "wget") -> RunStep {
        RunStep(engine: .homebrew, operation: .remove,
                spec: CommandSpec(executable: URL(fileURLWithPath: brewPath), arguments: ["uninstall", "--formula", name],
                                  needsRoot: false),
                title: "Remove \(name)", requiresAllEarlier: true)
    }

    static func ref(_ name: String, on engine: EngineID = .nanobrew) -> PackageRef {
        PackageRef(engine: engine, kind: .formula, name: name)
    }

    static func check(_ names: [String] = ["jq", "fd"], on engine: EngineID = .nanobrew) -> RunStep {
        RunStep.check(names.map { ref($0, on: engine) }, on: engine,
                      title: "Check \(engine.displayName) has the packages")
    }

    static let sudoVerify = ["/usr/bin/sudo", "-A", "-k", "-v"]
}

/// Records what a verifier was asked and answers with a fixed list of missing names.
final class VerifierProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [[PackageRef]] = []
    private let missing: Set<String>
    private let before: (@Sendable () -> Void)?

    init(missing: Set<String> = [], before: (@Sendable () -> Void)? = nil) {
        self.missing = missing
        self.before = before
    }

    var asked: [[PackageRef]] { lock.withLock { _asked } }

    var verify: InstalledVerifier {
        { [self] refs in
            lock.withLock { _asked.append(refs) }
            before?()
            return refs.filter { missing.contains($0.name) }
        }
    }
}

@Suite struct RunRoutingTests {
    @Test func routesPerEngine() {
        #expect(RunRouting.route(for: Steps.port()) == .helper)
        #expect(RunRouting.route(for: Steps.mas()) == .sudoAskpass)
        #expect(RunRouting.route(for: Steps.cask()) == .userWithAskpass)
        #expect(RunRouting.route(for: Steps.formula()) == .user)
        #expect(RunRouting.route(for: Steps.nanobrew()) == .user)
    }

    @Test func nanobrewGoesToSudoOnlyForItsOwnInit() {
        func step(_ path: String, _ arguments: [String], root: Bool = true) -> RunStep {
            RunStep(engine: .nanobrew, operation: .install,
                    spec: CommandSpec(executable: URL(fileURLWithPath: path), arguments: arguments, needsRoot: root),
                    title: "")
        }
        #expect(RunRouting.route(for: step(Steps.nbPath, ["init"])) == .sudoAskpass)
        #expect(RunRouting.route(for: step("/tmp/nb", ["init"])) == .user)
        #expect(RunRouting.route(for: step(Steps.nbPath, ["install", "x"])) == .user)
        #expect(RunRouting.route(for: step(Steps.nbPath, ["init"], root: false)) == .user)
    }

    @Test func rootlessPortAndMasRunAsTheUser() {
        let port = RunStep(engine: .macports, kind: .port,
                           operation: .upgrade,
                           spec: CommandSpec(executable: URL(fileURLWithPath: Steps.portPath),
                                             arguments: ["outdated"], needsRoot: false), title: "")
        #expect(RunRouting.route(for: port) == .user)
        #expect(RunRouting.route(for: Steps.mas(needsRoot: false)) == .user)
    }

    @Test func brewNeverGoesToRoot() {
        // Even if a spec claimed root, brew is never run as root.
        let step = RunStep(engine: .homebrew, kind: .formula,
                           operation: .upgrade,
                           spec: CommandSpec(executable: URL(fileURLWithPath: "/x"), arguments: [], needsRoot: true),
                           title: "")
        #expect(RunRouting.route(for: step) == .user)
    }

    @Test func setupStepRoutesToHelper() {
        #expect(RunRouting.route(for: Steps.setup(.macports)) == .helperSetup)
        #expect(RunRouting.route(for: Steps.setup(.commandLineTools)) == .helperSetup)
    }

    @Test func nbInitRoutesToSudoAskpass() {
        #expect(RunRouting.route(for: Steps.nbInit()) == .sudoAskpass)
    }

    @Test func nanobrewRootRoutesToSudoOnlyForInit() {
        let other = RunStep(engine: .nanobrew, kind: .formula, operation: .install,
                            spec: CommandSpec(executable: URL(fileURLWithPath: Steps.nbPath),
                                              arguments: ["install", "jq"], needsRoot: true), title: "")
        #expect(RunRouting.route(for: other) == .user)
        let notRoot = RunStep(engine: .nanobrew, kind: .formula, operation: .install,
                              spec: CommandSpec(executable: URL(fileURLWithPath: Steps.nbPath),
                                                arguments: ["init"], needsRoot: false), title: "")
        #expect(RunRouting.route(for: notRoot) == .user)
    }

    @Test func nbNormalStaysUser() {
        #expect(RunRouting.route(for: Steps.nanobrew()) == .user)
    }

    @Test func stepKindDefaultsToFormula() {
        #expect(Steps.formula().kind == .formula)
    }

    @Test func checkStepRoutesToUserWhateverItsEngineOrSpec() {
        // A MacPorts check with a spec that claims root (and even a setup target) still runs as the user.
        let step = RunStep(engine: .macports, kind: .port, operation: .install,
                           spec: CommandSpec(executable: URL(fileURLWithPath: Steps.portPath), arguments: ["x"],
                                             needsRoot: true),
                           title: "", setupTarget: .macports, verifyInstalled: [Steps.ref("x", on: .macports)])
        #expect(RunRouting.route(for: step) == .user)
        #expect(RunRouting.route(for: Steps.check(on: .macports)) == .user)
    }

    @Test func newStepFieldsDefaultOff() {
        #expect(Steps.formula().requiresAllEarlier == false)
        #expect(Steps.formula().verifyInstalled == nil)
    }
}

@Suite struct RunSessionTests {
    static let password = "correct horse battery staple"
    static let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester", "HOMEBREW_NO_AUTO_UPDATE": "1"]

    final class Harness: @unchecked Sendable {
        let runner = FakeRunner()
        let helper = FakeHelper()
        let passwords: FakePasswords
        private let lock = NSLock()
        private var _servers: [FakeAskpassServer] = []
        private var _serverError: Error?
        var servers: [FakeAskpassServer] { lock.withLock { _servers } }
        var serverError: Error? {
            get { lock.withLock { _serverError } }
            set { lock.withLock { _serverError = newValue } }
        }

        init(password: String? = RunSessionTests.password) {
            passwords = FakePasswords(password)
        }

        init(answers: [String?]) {
            passwords = FakePasswords(answers: answers)
        }

        func session(host: Arch = .arm64, isAdministrator: Bool? = true) -> RunSession {
            RunSession(runner: runner, helper: helper, passwords: passwords, askpassPath: "/fake/brewxport-askpass",
                       host: host, baseEnvironment: RunSessionTests.base, isAdministrator: { isAdministrator },
                       makeAskpassServer: { [self] _, _ in
                           try lock.withLock {
                               if let error = _serverError { throw error }
                               let server = FakeAskpassServer()
                               _servers.append(server)
                               return server
                           }
                       })
        }
    }

    // MARK: The brief's tests

    @Test func promptsOnceForMixedRun() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.port(), Steps.cask(), Steps.mas()]))
        #expect(h.passwords.calls == 1)
        #expect(h.helper.authorizeCalls == 1)
        #expect(h.runner.calls.filter { [$0.executable.path] + $0.arguments == Steps.sudoVerify }.count == 1)
        #expect(h.servers.count == 1)
        #expect(events.first == .needsPassword)
        #expect(events.last == .done)
        #expect(events.filter { $0 == .needsPassword }.count == 1)
        for i in 0..<3 {
            #expect(events.contains(.started(i)))
            #expect(events.contains(.finished(i, 0)))
        }
    }

    @Test func noPromptWhenNoRoot() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.formula(), Steps.nanobrew(), Steps.mas(needsRoot: false)]))
        #expect(h.passwords.calls == 0)
        #expect(h.helper.authorizeCalls == 0)
        #expect(h.servers.isEmpty)
        #expect(!events.contains(.needsPassword))
        #expect(h.runner.calls.allSatisfy { $0.streamed })
        #expect(h.runner.calls.allSatisfy { $0.environment == nil })  // the runner's base environment
        #expect(events == [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .started(2), .finished(2, 0),
                           .done])
    }

    static let rejected: [Error?] = Array(repeating: HelperError.notAuthorized, count: RunSession.passwordAttempts)

    @Test func wrongPasswordStopsBeforeFirstCommand() async {
        // Rejected by the helper's authorization, every time.
        let h = Harness()
        h.helper.authorizeResults = Self.rejected
        let start = ContinuousClock.now
        let events = await collect(h.session().run([Steps.port(), Steps.cask(), Steps.formula()]))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(events == [.needsPassword, .passwordRejected, .done])
        #expect(h.passwords.calls == 3)
        #expect(h.runner.streamedCalls.isEmpty)
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.allSatisfy { $0.stops >= 1 })

        // Rejected by sudo, every time: one askpass server per attempt, each stopped once.
        let s = Harness()
        s.runner.respond(Steps.sudoVerify, code: 1)
        let sudoEvents = await collect(s.session().run([Steps.port(), Steps.mas(), Steps.formula()]))
        #expect(sudoEvents == [.needsPassword, .passwordRejected, .done])
        #expect(s.runner.streamedCalls.isEmpty)
        #expect(s.helper.runCalls.isEmpty)
        #expect(s.passwords.given.count == 3)
        #expect(s.passwords.given.allSatisfy { $0.isWiped })
        #expect(s.servers.count == 3)
        #expect(s.servers.allSatisfy { $0.stops == 1 })
        #expect(s.helper.endCalls == 1)
    }

    // MARK: Password retry

    @Test func wrongPasswordAsksAgain() async {
        let h = Harness()
        h.helper.authorizeResults = [HelperError.notAuthorized]
        let events = await collect(h.session().run([Steps.port()]))
        #expect(h.passwords.calls == 2)
        #expect(h.passwords.retries == [false, true])
        #expect(h.passwords.reasons == [RunSession.passwordReason, RunSession.passwordReason])
        // The rejected password was wiped before the second ask.
        #expect(h.passwords.earlierWiped == [true, true])
        #expect(h.passwords.given.first?.isWiped == true)
        // One `.needsPassword` for the run; a rejection that's retried isn't an event.
        #expect(events == [.needsPassword, .started(0), .output(0, .stdout("port -N upgrade wget")),
                           .finished(0, 0), .done])

        // The same through sudo: the first attempt's askpass server is stopped before the second ask.
        let s = Harness(answers: ["wrong", Self.password])
        s.runner.respondOnce(Steps.sudoVerify, code: 1, stderr: Self.wrongPasswordStderr)
        s.passwords.onAsk = { [s] in s.servers.allSatisfy { $0.stops >= 1 } }
        let sudoEvents = await collect(s.session().run([Steps.mas()]))
        #expect(s.passwords.retries == [false, true])
        #expect(s.passwords.earlierWiped == [true, true])
        #expect(s.passwords.onAskResults == [true, true])
        #expect(s.servers.count == 2)
        #expect(s.servers.allSatisfy { $0.stops == 1 })
        #expect(sudoEvents == [.needsPassword, .started(0), .finished(0, 0), .done])
        #expect(s.runner.streamedCalls.count == 1)
        #expect(s.runner.calls.filter { [$0.executable.path] + $0.arguments == Steps.sudoVerify }.count == 2)
    }

    @Test func thirdWrongPasswordEndsRun() async {
        #expect(RunSession.passwordAttempts == 3)
        let h = Harness(answers: ["one", "two", "three", "never asked"])
        h.helper.authorizeResults = Self.rejected + [nil]
        let events = await collect(h.session().run([Steps.port(), Steps.formula()]))
        #expect(events == [.needsPassword, .passwordRejected, .done])
        #expect(h.passwords.calls == 3)
        #expect(h.passwords.retries == [false, true, true])
        #expect(h.passwords.earlierWiped == [true, true, true])
        #expect(h.helper.authorizeCalls == 3)
        #expect(h.helper.secretsSeen == [Array("one".utf8), Array("two".utf8), Array("three".utf8)])
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.runner.calls.isEmpty)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.helper.endCalls == 1)
    }

    @Test func cancelOnRetryEndsRun() async {
        let h = Harness(answers: ["wrong", nil])
        h.helper.authorizeResults = [HelperError.notAuthorized]
        let events = await collect(h.session().run([Steps.port(), Steps.cask(), Steps.formula()]))
        #expect(events == [.needsPassword, .cancelled, .done])
        #expect(h.passwords.calls == 2)
        #expect(h.passwords.retries == [false, true])
        #expect(h.helper.authorizeCalls == 1)
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.runner.calls.isEmpty)
        #expect(h.servers.isEmpty)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.helper.endCalls == 1)
    }

    @Test func rightPasswordOnSecondTryRunsSteps() async throws {
        let h = Harness(answers: ["wrong", Self.password])
        h.helper.authorizeResults = [HelperError.notAuthorized]
        let events = await collect(h.session().run([Steps.port(), Steps.cask(), Steps.mas()]))
        #expect(h.passwords.calls == 2)
        #expect(h.helper.secretsSeen == [Array("wrong".utf8), Array(Self.password.utf8)])
        #expect(events.first == .needsPassword)
        #expect(events.filter { $0 == .needsPassword }.count == 1)
        #expect(!events.contains(.passwordRejected))
        for i in 0..<3 { #expect(events.contains(.finished(i, 0))) }
        #expect(events.last == .done)
        #expect(h.helper.runCalls.first?.authorization == FakeHelper.token)
        // The first attempt stopped at the helper, so only the second made an askpass server and checked sudo.
        #expect(h.servers.count == 1)
        #expect(h.runner.calls.filter { [$0.executable.path] + $0.arguments == Steps.sudoVerify }.count == 1)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.first?.stops == 1)
        #expect(h.helper.endCalls == 1)
    }

    @Test func otherFailuresOnRetryAreNotRetried() async {
        // A retry that turns out to be "not an administrator" ends the run as that, with no third ask.
        let h = Harness(answers: ["wrong", Self.password])
        h.runner.respondOnce(Steps.sudoVerify, code: 1, stderr: Self.wrongPasswordStderr)
        h.runner.respond(Steps.sudoVerify, code: 1, stderr: Self.notInSudoersStderr)
        let events = await collect(h.session().run([Steps.mas()]))
        #expect(events == [.needsPassword, .privilegeUnavailable(RunSession.notAnAdministrator), .done])
        #expect(h.passwords.calls == 2)
        #expect(h.runner.streamedCalls.isEmpty)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.allSatisfy { $0.stops == 1 })
    }

    @Test func masRunsUnderSudoA() async throws {
        let h = Harness()
        _ = await collect(h.session().run([Steps.mas("497799835")]))
        let call = try #require(h.runner.streamedCalls.first)
        #expect(call.executable.path == "/usr/bin/sudo")
        #expect(call.arguments == ["-A", Steps.masPath, "upgrade", "497799835"])
        let env = try #require(call.environment)
        let server = try #require(h.servers.first)
        #expect(env == RunSessionTests.base.merging(server.environment) { $1 })
        #expect(h.helper.authorizeCalls == 0)  // no helper step, no helper authorization
    }

    @Test func brewCaskGetsAskpassEnvWithoutSecret() async throws {
        // The real AskpassServer this time; /usr/bin/true stands in for brewxport-askpass.
        let runner = FakeRunner()
        let helper = FakeHelper()
        let passwords = FakePasswords(Self.password)
        let session = RunSession(runner: runner, helper: helper, passwords: passwords, askpassPath: "/usr/bin/true",
                                 host: .arm64, baseEnvironment: Self.base, isAdministrator: { true })
        _ = await collect(session.run([Steps.cask("blackhole-2ch")]))
        let call = try #require(runner.streamedCalls.first)
        #expect(call.executable.path == Steps.brewPath)
        #expect(call.arguments == ["upgrade", "--cask", "blackhole-2ch"])
        let env = try #require(call.environment)
        #expect(Set(env.keys) == Set(Self.base.keys).union(
            ["SUDO_ASKPASS", "HOMEBREW_BREWXPORT_ASKPASS_SOCKET", "HOMEBREW_BREWXPORT_ASKPASS_NONCE"]))
        #expect(env["SUDO_ASKPASS"] == "/usr/bin/true")
        for (key, value) in Self.base { #expect(env[key] == value) }
        // The socket is gone once the run is over.
        let socket = try #require(env["HOMEBREW_BREWXPORT_ASKPASS_SOCKET"])
        #expect(!FileManager.default.fileExists(atPath: socket))
        // No env value or argument of any call (the verify call included) holds the password or a piece of it.
        let pieces = [Self.password, String(Self.password.prefix(8)), String(Self.password.suffix(8))]
        #expect(runner.calls.count == 2)
        for c in runner.calls {
            for piece in pieces {
                #expect(!(c.environment ?? [:]).values.contains { $0.contains(piece) })
                #expect(!(c.environment ?? [:]).keys.contains { $0.contains(piece) })
                #expect(!c.arguments.contains { $0.contains(piece) })
            }
        }
        #expect(passwords.given.allSatisfy { $0.isWiped })
    }

    @Test func portGoesToHelper() async throws {
        let h = Harness()
        let events = await collect(h.session().run([Steps.port("wget")]))
        #expect(h.runner.streamedCalls.isEmpty)
        let run = try #require(h.helper.runCalls.first)
        #expect(run.arguments == ["-N", "upgrade", "wget"])
        #expect(run.authorization == FakeHelper.token)
        #expect(h.helper.secretsSeen == [Array(Self.password.utf8)])
        #expect(events == [.needsPassword, .started(0), .output(0, .stdout("port -N upgrade wget")),
                           .finished(0, 0), .done])
        // Only the helper needs the password: no sudo verify, no askpass server.
        #expect(h.runner.calls.isEmpty)
        #expect(h.servers.isEmpty)
    }

    // MARK: Uninstalling what is already gone

    /// Homebrew's own message for a package whose keg folder isn't there.
    static let noSuchKeg = "Error: No such keg: /opt/homebrew/Cellar/wget"

    @Test func noSuchKegCountsAsAlreadyRemoved() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.output(0, .stderr(Self.noSuchKeg))))
        #expect(events.contains(.output(0, .stdout("wget was already removed."))))
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func formulaFlagDoesNotHideNoSuchKeg() async {
        // The exact shape the engine builds: `brew uninstall --formula wget`.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func noSuchKegOnIntelCountsToo() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1,
                         stderr: "Error: No such keg: /usr/local/Cellar/wget")
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func noSuchKegAlongsideAnotherErrorStillFails() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1,
                         stderr: Self.noSuchKeg + "\nError: Refusing to uninstall /opt/homebrew/Cellar/openssl@3/3.4.0\n"
                         + "because it is required by curl, which is currently installed.")
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.output(0, .stdout("wget was already removed."))))
    }

    @Test func noSuchKegInAMultiPackageUninstallStillFails() async {
        let h = Harness()
        let step = RunStep(engine: .homebrew, operation: .remove,
                           spec: CommandSpec(executable: URL(fileURLWithPath: Steps.brewPath),
                                             arguments: ["uninstall", "--formula", "wget", "jq"], needsRoot: false),
                           title: "Remove wget, jq")
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget", "jq"], code: 1, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([step]))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.output(0, .stdout("wget was already removed."))))
    }

    @Test func noSuchKegForAnotherPackageStillFails() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "jq"], code: 1, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([Steps.remove("jq")]))
        #expect(events.contains(.finished(0, 1)))
    }

    @Test func noSuchKegUnderRosettaCountsAsAlreadyRemoved() async {
        let h = Harness()
        let step = RunStep(engine: .homebrew, operation: .remove,
                           spec: CommandSpec(executable: URL(fileURLWithPath: Steps.intelBrewPath),
                                             arguments: ["uninstall", "--formula", "wget"], needsRoot: false, arch: .x86_64),
                           title: "Remove wget")
        h.runner.respond(["/usr/bin/arch", "-x86_64", Steps.intelBrewPath, "uninstall", "--formula", "wget"], code: 1,
                         stderr: "Error: No such keg: /usr/local/Cellar/wget")
        let events = await collect(h.session(host: .arm64).run([step]))
        #expect(events.contains(.output(0, .stdout("wget was already removed."))))
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func noSuchKegWithExitStatusTwoStillFails() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 2, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.finished(0, 2)))
    }

    @Test func otherUninstallFailuresAreUnchanged() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1, stderr: "Error: Permission denied @ apply2files")
        let events = await collect(h.session().run([Steps.remove("wget")]))
        #expect(events.contains(.finished(0, 1)))
    }

    @Test func noSuchKegOnAnUpgradeStaysAFailure() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "wget"], code: 1, stderr: Self.noSuchKeg)
        let events = await collect(h.session().run([Steps.formula("wget")]))
        #expect(events.contains(.finished(0, 1)))
    }

    @Test func continuesAfterFailedStep() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "wget"], code: 1, stdout: ["Error: boom"])
        h.helper.runResults = [.code(3)]
        let events = await collect(h.session().run([Steps.formula("wget"), Steps.port(), Steps.nanobrew()]))
        #expect(events.contains(.output(0, .stdout("Error: boom"))))
        #expect(events.contains(.finished(0, 1)))
        #expect(events.contains(.finished(1, 3)))
        #expect(events.contains(.finished(2, 0)))
        #expect(events.last == .done)
    }

    @Test func cancelWipesPasswordAndStops() async {
        let h = Harness()
        h.runner.block([Steps.brewPath, "upgrade", "--cask", "blackhole-2ch"])
        let session = h.session()
        let collector = Task { await collect(session.run([Steps.port(), Steps.cask(), Steps.mas()])) }
        await h.runner.waitForBlockingCall()
        session.cancel()
        let events = await collector.value
        #expect(Array(events.suffix(2)) == [.cancelled, .done])
        #expect(events.contains(.finished(0, 0)))
        #expect(events.contains(.started(1)))
        #expect(!events.contains(.finished(1, 0)))
        #expect(!events.contains(.started(2)))
        #expect(!h.runner.streamedCalls.contains { $0.executable.path == "/usr/bin/sudo" })  // mas never ran
        #expect(h.passwords.given.count == 1)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.first?.stops == 1)
        #expect(h.helper.endCalls == 1)
    }

    @Test func cancellingTheConsumerCancelsTheRun() async {
        let h = Harness()
        h.runner.block([Steps.brewPath, "upgrade", "--cask", "blackhole-2ch"])
        let session = h.session()
        let consumer = Task { await collect(session.run([Steps.cask(), Steps.mas()])) }
        await h.runner.waitForBlockingCall()
        consumer.cancel()
        _ = await consumer.value
        // The stream is already gone, so the side effects are what we can see.
        #expect(await eventually { h.helper.endCalls == 1 })
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.first?.stops == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.runner.streamedCalls.count == 1)  // mas never started
    }

    @Test func userCancelledPasswordRunsNothing() async {
        let h = Harness(password: nil)
        let events = await collect(h.session().run([Steps.port(), Steps.formula()]))
        #expect(events == [.needsPassword, .cancelled, .done])
        #expect(h.runner.calls.isEmpty)
        #expect(h.helper.authorizeCalls == 0)
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.servers.isEmpty)
    }

    // MARK: Setup steps

    @Test func sessionCallsSetUpEngineWithTarget() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.setup(.macports)]))
        #expect(h.helper.setupCalls.map(\.target) == [.macports])
        #expect(h.helper.setupCalls.first?.authorization == FakeHelper.token)
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.passwords.calls == 1)
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func setupReauthorizesOnce() async {
        let h = Harness()
        h.helper.setupResults = [.fail(HelperError.notAuthorized), .code(0)]
        let events = await collect(h.session().run([Steps.setup(.nanobrew)]))
        #expect(h.helper.authorizeCalls == 2)
        #expect(h.helper.setupCalls.map(\.target) == [.nanobrew, .nanobrew])
        #expect(events.contains(.finished(0, 0)))
    }

    @Test func dependentStepIsSkippedAfterFailedSetup() async {
        let h = Harness()
        h.helper.setupResults = [.code(1)]
        let later = Steps.formula("wget")
        let events = await collect(h.session().run([Steps.setup(.nanobrew), Steps.nbInit(), later]))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        #expect(!events.contains { if case .finished(1, _) = $0 { true } else { false } })
        #expect(h.runner.calls.allSatisfy { $0.arguments != ["-A", Steps.nbPath, "init"] })
        // The independent step after it still runs.
        #expect(events.contains(.started(2)))
        #expect(events.contains(.finished(2, 0)))
    }

    @Test func dependentStepRunsAfterSuccessfulSetup() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.setup(.nanobrew), Steps.nbInit()]))
        #expect(events.contains(.finished(1, 0)))
    }

    // MARK: Rulings

    @Test func reauthorizesOnceWhenHelperRightExpires() async {
        // The right ran out before step 0: re-authorize with the held secret and retry once.
        let h = Harness()
        h.helper.runResults = [.fail(HelperError.notAuthorized), .code(0)]
        let events = await collect(h.session().run([Steps.port()]))
        #expect(h.helper.authorizeCalls == 2)
        #expect(h.helper.runCalls.count == 2)
        #expect(h.helper.secretsSeen == [Array(Self.password.utf8), Array(Self.password.utf8)])
        #expect(events.contains(.finished(0, 0)))

        // A second refusal fails only that step; the run goes on.
        let s = Harness()
        s.helper.runResults = [.fail(HelperError.notAuthorized), .fail(HelperError.notAuthorized), .code(0)]
        let more = await collect(s.session().run([Steps.port("a"), Steps.port("b")]))
        #expect(s.helper.authorizeCalls == 2)
        #expect(s.helper.runCalls.map(\.arguments) == [["-N", "upgrade", "a"], ["-N", "upgrade", "a"],
                                                       ["-N", "upgrade", "b"]])
        #expect(more.contains(.output(0, .stderr(HelperError.notAuthorized.message))))
        #expect(more.contains(.finished(0, -1)))
        #expect(more.contains(.finished(1, 0)))
        #expect(more.last == .done)

        // A re-authorization that itself fails also fails only that step.
        let r = Harness()
        r.helper.runResults = [.fail(HelperError.notAuthorized), .code(0)]
        r.helper.authorizeResults = [nil, HelperError.notAuthorized]
        let third = await collect(r.session().run([Steps.port("a"), Steps.port("b")]))
        #expect(third.contains(.finished(0, -1)))
        #expect(third.contains(.finished(1, 0)))
    }

    @Test func endAuthorizationCalledOnEveryExit() async {
        let done = Harness()
        _ = await collect(done.session().run([Steps.port(), Steps.formula()]))
        #expect(done.helper.endCalls == 1)

        let rootless = Harness()
        _ = await collect(rootless.session().run([Steps.formula()]))
        #expect(rootless.helper.endCalls == 1)

        let rejected = Harness()
        rejected.helper.authorizeResults = Self.rejected
        _ = await collect(rejected.session().run([Steps.port()]))
        #expect(rejected.helper.endCalls == 1)

        let noPassword = Harness(password: nil)
        _ = await collect(noPassword.session().run([Steps.port()]))
        #expect(noPassword.helper.endCalls == 1)

        let cancelled = Harness()
        cancelled.runner.block([Steps.brewPath, "upgrade", "wget"])
        let session = cancelled.session()
        let collector = Task { await collect(session.run([Steps.port(), Steps.formula()])) }
        await cancelled.runner.waitForBlockingCall()
        session.cancel()
        _ = await collector.value
        #expect(cancelled.helper.endCalls == 1)
    }

    @Test func launchCommandUsedForIntelBrew() async throws {
        let h = Harness()
        _ = await collect(h.session(host: .arm64).run([
            Steps.formula("wget", brew: Steps.intelBrewPath, arch: .x86_64),
            Steps.cask("blackhole-2ch", brew: Steps.intelBrewPath, arch: .x86_64),
        ]))
        let calls = h.runner.streamedCalls
        #expect(calls.count == 2)
        #expect(calls.map(\.executable.path) == ["/usr/bin/arch", "/usr/bin/arch"])
        #expect(calls.first?.arguments == ["-x86_64", Steps.intelBrewPath, "upgrade", "wget"])
        #expect(calls.last?.arguments == ["-x86_64", Steps.intelBrewPath, "upgrade", "--cask", "blackhole-2ch"])
        #expect(calls.last?.environment?["SUDO_ASKPASS"] != nil)

        // On an Intel host the same specs run directly.
        let intel = Harness()
        _ = await collect(intel.session(host: .x86_64).run([Steps.formula("wget", brew: Steps.intelBrewPath,
                                                                          arch: .x86_64)]))
        #expect(intel.runner.streamedCalls.first?.executable.path == Steps.intelBrewPath)
    }

    // MARK: Failures that aren't a wrong password

    @Test func helperUnavailableFailsOnlyHelperSteps() async {
        struct Down: Error {}
        let h = Harness()
        h.helper.authorizeResults = [Down()]
        let events = await collect(h.session().run([Steps.port(), Steps.formula()]))
        #expect(!events.contains(.passwordRejected))
        #expect(events.contains(.finished(0, -1)))
        #expect(events.contains { if case .output(0, .stderr) = $0 { true } else { false } })
        #expect(events.contains(.finished(1, 0)))
        #expect(h.helper.runCalls.isEmpty)
    }

    // sudo's stderr for these cases. The askpass lines were captured on macOS 27 (sudo 1.9) with
    // `env -u SUDO_ASKPASS /usr/bin/sudo -A -k -v` and `SUDO_ASKPASS=/nonexistent/brewxport-askpass sudo -A -k -v`.
    // The wrong-password lines are the ones the Plan 2 end-to-end run recorded (private/spikes/2026-11-plan2-e2e.md).
    // The not-in-sudoers line is NOT captured (this Mac's account is an administrator): it's sudo 1.9's
    // "%s is not in the sudoers file." with a placeholder user name.
    static let noAskpassStderr = "sudo: no askpass program specified, try setting SUDO_ASKPASS\n"
    static let missingAskpassStderr = """
        sudo: unable to run /nonexistent/brewxport-askpass: No such file or directory
        sudo: no password was provided
        sudo: a password is required

        """
    static let notInSudoersStderr = "someuser is not in the sudoers file.\n"
    static let wrongPasswordStderr = "sudo: 1 incorrect password attempt\n"

    @Test func sudoFailureClassification() {
        #expect(RunSession.privilegeUnavailable(sudoStderr: Self.notInSudoersStderr) == RunSession.notAnAdministrator)
        #expect(RunSession.privilegeUnavailable(sudoStderr: "Sorry, user someuser may not run sudo on host.\n")
                == RunSession.notAnAdministrator)
        #expect(RunSession.privilegeUnavailable(sudoStderr: Self.noAskpassStderr)
                == "BrewxPort couldn't pass the password to sudo: sudo: no askpass program specified, try setting SUDO_ASKPASS")
        #expect(RunSession.privilegeUnavailable(sudoStderr: Self.missingAskpassStderr)
                == "BrewxPort couldn't pass the password to sudo: sudo: unable to run /nonexistent/brewxport-askpass: No such file or directory")
        #expect(RunSession.privilegeUnavailable(sudoStderr: Self.wrongPasswordStderr) == nil)
        #expect(RunSession.privilegeUnavailable(sudoStderr: "") == nil)
    }

    @Test func notAnAdministratorIsNotAWrongPassword() async {
        let h = Harness()
        h.runner.respond(Steps.sudoVerify, code: 1, stderr: Self.notInSudoersStderr)
        let events = await collect(h.session().run([Steps.mas(), Steps.formula()]))
        #expect(events == [.needsPassword, .privilegeUnavailable(RunSession.notAnAdministrator), .done])
        #expect(h.runner.streamedCalls.isEmpty)
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
        #expect(h.servers.first?.stops == 1)
    }

    @Test func askpassThatCannotRunIsNotAWrongPassword() async {
        let h = Harness()
        h.runner.respond(Steps.sudoVerify, code: 1, stderr: Self.missingAskpassStderr)
        let events = await collect(h.session().run([Steps.cask()]))
        guard events.count == 3, case .privilegeUnavailable(let reason) = events[1] else {
            Issue.record("expected privilegeUnavailable, got \(events)")
            return
        }
        #expect(reason.contains("unable to run"))
        #expect(!events.contains(.passwordRejected))
        #expect(h.runner.streamedCalls.isEmpty)
    }

    @Test func nonAdminGetsPrivilegeUnavailableWithoutPrompt() async {
        let h = Harness()
        let events = await collect(h.session(isAdministrator: false).run([Steps.port(), Steps.formula()]))
        #expect(events == [.privilegeUnavailable(RunSession.notAnAdministrator), .done])
        #expect(h.passwords.calls == 0)
        #expect(h.helper.authorizeCalls == 0)
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.runner.calls.isEmpty)
        #expect(h.servers.isEmpty)
    }

    @Test func adminProceeds() async {
        for admin in [true, nil] as [Bool?] {  // nil: the check itself failed, so authd and sudo decide
            let h = Harness()
            let events = await collect(h.session(isAdministrator: admin).run([Steps.port(), Steps.mas()]))
            #expect(h.passwords.calls == 1)
            #expect(events.first == .needsPassword)
            #expect(events.contains(.finished(0, 0)))
            #expect(events.contains(.finished(1, 0)))
        }
        // A run with no root steps never asks, admin or not.
        let user = Harness()
        let events = await collect(user.session(isAdministrator: false).run([Steps.formula()]))
        #expect(events == [.started(0), .finished(0, 0), .done])
    }

    @Test func liveAdminCheckAnswers() {
        // Whatever this account is, the real check must answer rather than fail.
        #expect(AdminMembership.currentUserIsAdmin() != nil)
    }

    @Test func wrongPasswordStderrIsStillRejected() async {
        let h = Harness()
        h.runner.respond(Steps.sudoVerify, code: 1, stderr: Self.wrongPasswordStderr)
        #expect(await collect(h.session().run([Steps.mas()])) == [.needsPassword, .passwordRejected, .done])
    }

    @Test func authorizationFailureOtherThanPasswordIsUnavailable() async {
        let h = Harness()
        h.helper.authorizeResults = [AppAuthorizationError.failed(-60008)]
        let events = await collect(h.session().run([Steps.port(), Steps.formula()]))
        #expect(events == [.needsPassword,
                           .privilegeUnavailable("macOS didn't grant administrator rights (authorization error -60008)."),
                           .done])
        #expect(h.helper.runCalls.isEmpty)
        #expect(h.runner.streamedCalls.isEmpty)
        #expect(h.helper.endCalls == 1)
    }

    @Test func askpassServerFailureFailsOnlyAskpassSteps() async {
        let h = Harness()
        h.serverError = AskpassServerError.askpassNotFound
        let events = await collect(h.session().run([Steps.mas(), Steps.port(), Steps.cask()]))
        #expect(!events.contains(.passwordRejected))
        #expect(events.contains(.finished(0, -1)))
        #expect(events.contains(.finished(1, 0)))
        #expect(events.contains(.finished(2, -1)))
        #expect(!h.runner.calls.contains { $0.executable.path == "/usr/bin/sudo" })
        #expect(h.passwords.given.allSatisfy { $0.isWiped })
    }

    @Test func launchFailureFailsTheStepAndContinues() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "wget"], error: .launchFailed("brew: Bad CPU type"))
        let events = await collect(h.session().run([Steps.formula("wget"), Steps.nanobrew()]))
        #expect(events.contains(.finished(0, -1)))
        #expect(events.contains(.output(0, .stderr("Couldn't run the command: brew: Bad CPU type"))))
        #expect(events.contains(.finished(1, 0)))
    }

    @Test func emptyRunIsJustDone() async {
        let h = Harness()
        #expect(await collect(h.session().run([])) == [.done])
    }

    @Test func cancelAfterCleanStepStillReportsFinished() async {
        let h = Harness()
        let session = h.session()
        h.runner.onStream = { index in
            if index == 0 { session.cancel() }
        }
        let events = await collect(session.run([Steps.formula(), Steps.nanobrew()]))
        #expect(events == [.started(0), .finished(0, 0), .cancelled, .done])
        #expect(!events.contains(.started(1)))
    }

    // MARK: Gates and check steps

    @Test func allEarlierSkipsAfterAnyFailure() async {
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "b"], code: 1)
        let steps = [Steps.formula("a"), Steps.formula("b"), Steps.formula("c"), Steps.remove("x")]
        let events = await collect(h.session().run(steps))
        #expect(events == [.started(0), .finished(0, 0), .started(1), .finished(1, 1), .started(2), .finished(2, 0),
                           .done])
        #expect(!h.runner.calls.contains { $0.arguments == ["uninstall", "x"] })
    }

    @Test func allEarlierRunsWhenEverythingSucceeded() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.formula("a"), Steps.remove("x"), Steps.remove("y")]))
        #expect(events.contains(.finished(1, 0)))
        #expect(events.contains(.finished(2, 0)))
    }

    static func dependent(_ name: String) -> RunStep {
        RunStep(engine: .homebrew, operation: .upgrade,
                spec: CommandSpec(executable: URL(fileURLWithPath: Steps.brewPath), arguments: ["upgrade", name],
                                  needsRoot: false),
                title: name, dependsOnPrevious: true)
    }

    @Test func dependencyChainOfThreeSkipsEveryLinkAfterAFailure() async {
        // a fails; b depends on a, c depends on b: both stay unstarted. d depends on nothing and runs.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "a"], code: 1)
        let steps = [Steps.formula("a"), Self.dependent("b"), Self.dependent("c"), Steps.formula("d")]
        let events = await collect(h.session().run(steps))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        #expect(!events.contains(.started(2)))
        #expect(events.contains(.finished(3, 0)))
        #expect(h.runner.calls.map(\.arguments) == [["upgrade", "a"], ["upgrade", "d"]])
    }

    @Test func dependencyChainOfThreeRunsWhenEachLinkSucceeds() async {
        let h = Harness()
        let steps = [Steps.formula("a"), Self.dependent("b"), Self.dependent("c")]
        let events = await collect(h.session().run(steps))
        for index in 0..<3 { #expect(events.contains(.finished(index, 0))) }
    }

    @Test func allEarlierSkipsAfterSkipped() async {
        // Step 1 is skipped (its own dependency failed); a later gated step counts that as a failure, even though
        // the step right before it succeeded.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "a"], code: 1)
        let dependent = RunStep(engine: .homebrew, operation: .upgrade,
                                spec: CommandSpec(executable: URL(fileURLWithPath: Steps.brewPath),
                                                  arguments: ["upgrade", "b"], needsRoot: false),
                                title: "b", dependsOnPrevious: true)
        let steps = [Steps.formula("a"), dependent, Steps.formula("c"), Steps.remove("x")]
        let events = await collect(h.session().run(steps))
        #expect(!events.contains(.started(1)))
        #expect(events.contains(.finished(2, 0)))
        #expect(!events.contains(.started(3)))
    }

    @Test func stepAfterGatedSkipCountsItAsNotSucceeded() async {
        // ok, fail, ok, gated (skipped), then a step that depends on the gated one: it must not run either.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "upgrade", "b"], code: 1)
        let afterGate = RunStep(engine: .homebrew, operation: .upgrade,
                                spec: CommandSpec(executable: URL(fileURLWithPath: Steps.brewPath),
                                                  arguments: ["upgrade", "d"], needsRoot: false),
                                title: "d", dependsOnPrevious: true)
        let steps = [Steps.formula("a"), Steps.formula("b"), Steps.formula("c"), Steps.remove("x"), afterGate]
        let events = await collect(h.session().run(steps))
        #expect(!events.contains(.started(3)))
        #expect(!events.contains(.started(4)))
        #expect(!h.runner.calls.contains { $0.arguments == ["upgrade", "d"] })
    }

    /// A gated removal on Homebrew (`nanobrew: false`) or nanobrew, scoped to its own engine's group.
    static func groupedRemove(_ name: String, nanobrew: Bool = false) -> RunStep {
        let engine: EngineID = nanobrew ? .nanobrew : .homebrew
        let path = nanobrew ? Steps.nbPath : Steps.brewPath
        return RunStep(engine: engine, operation: .remove,
                       spec: CommandSpec(executable: URL(fileURLWithPath: path),
                                         arguments: nanobrew ? ["remove", name] : ["uninstall", "--formula", name],
                                         needsRoot: false),
                       title: "Remove \(name)", requiresAllEarlier: true, gateGroup: engine.rawValue)
    }

    @Test func groupedGateIgnoresOtherGroupsFailures() async {
        // Homebrew's wget fails: Homebrew's later libidn2 is skipped, nanobrew's jq and fd still run.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1)
        let steps = [Self.groupedRemove("wget"), Self.groupedRemove("jq", nanobrew: true),
                     Self.groupedRemove("libidn2"), Self.groupedRemove("fd", nanobrew: true)]
        let events = await collect(h.session().run(steps))
        #expect(events == [.started(0), .finished(0, 1), .started(1), .finished(1, 0), .started(3), .finished(3, 0),
                           .done])
        #expect(!h.runner.calls.contains { $0.arguments == ["uninstall", "--formula", "libidn2"] })
    }

    @Test func groupedGateCountsASkippedStepInItsGroup() async {
        // wget fails, libidn2 is skipped, so openssl (after a skip, not a failure) is skipped too.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "wget"], code: 1)
        let steps = [Self.groupedRemove("wget"), Self.groupedRemove("libidn2"), Self.groupedRemove("jq", nanobrew: true),
                     Self.groupedRemove("openssl")]
        let events = await collect(h.session().run(steps))
        #expect(!events.contains(.started(1)))
        #expect(events.contains(.finished(2, 0)))
        #expect(!events.contains(.started(3)))
    }

    @Test func ungroupedGateStillWaitsOnEveryEarlierStep() async {
        // A grouped failure still stops a gated step without a group: nil keeps the whole-run meaning.
        let h = Harness()
        h.runner.respond([Steps.nbPath, "remove", "jq"], code: 1)
        let events = await collect(h.session().run([Self.groupedRemove("jq", nanobrew: true), Steps.remove("x")]))
        #expect(events == [.started(0), .finished(0, 1), .done])
        #expect(Steps.remove().gateGroup == nil)
    }

    @Test func checkStepPassesWhenNothingMissing() async {
        let h = Harness()
        let probe = VerifierProbe()
        let check = Steps.check(["jq", "fd"])
        let events = await collect(h.session().run([Steps.nanobrew("jq"), check, Steps.remove("jq")], reason: "R",
                                                   verify: probe.verify))
        #expect(probe.asked == [[Steps.ref("jq"), Steps.ref("fd")]])
        #expect(events == [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .started(2), .finished(2, 0),
                           .done])
        // The check's spec is never launched.
        #expect(!h.runner.calls.contains { $0.executable.path == "/usr/bin/false" })
        #expect(h.runner.calls.count == 2)
    }

    @Test func checkStepFailsAndNamesMissing() async {
        let h = Harness()
        let probe = VerifierProbe(missing: ["fd", "rg"])
        let check = Steps.check(["jq", "fd", "rg"])
        let events = await collect(h.session().run([check, Steps.remove("jq")], reason: "R", verify: probe.verify))
        let stderr = events.compactMap { event -> String? in
            if case .output(0, .stderr(let line)) = event { line } else { nil }
        }
        #expect(stderr == ["Not found on nanobrew: fd, rg"])
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func checkStepNeedsNoPassword() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.formula(), Steps.check(on: .macports), Steps.nanobrew()],
                                                   reason: "R", verify: VerifierProbe().verify))
        #expect(!events.contains(.needsPassword))
        #expect(h.passwords.calls == 0)
        #expect(h.helper.authorizeCalls == 0)
        #expect(events.contains(.finished(1, 0)))
    }

    @Test func defaultVerifierFailsClosed() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.check(["jq"]), Steps.remove("jq")]))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        let r = Harness()
        let viaReason = await collect(r.session().run([Steps.check(["jq"])], reason: "R"))
        #expect(viaReason.contains(.finished(0, 1)))
        #expect(await RunSession.failClosed([Steps.ref("jq")]) == [Steps.ref("jq")])
    }

    @Test func cancelAfterInstallsRemovesNothing() async {
        // Worst case: the run is cancelled while the check runs, and the check then says everything is there.
        let h = Harness()
        let session = h.session()
        let probe = VerifierProbe(before: { session.cancel() })
        let steps = [Steps.nanobrew("jq"), Steps.check(["jq"]), Steps.remove("jq"), Steps.remove("fd")]
        let events = await collect(session.run(steps, reason: "R", verify: probe.verify))
        #expect(probe.asked.count == 1)
        #expect(Array(events.suffix(2)) == [.cancelled, .done])
        #expect(!events.contains(.finished(1, 0)))
        #expect(!events.contains(.started(2)))
        #expect(!events.contains(.started(3)))
        #expect(!h.runner.calls.contains { $0.arguments.first == "uninstall" })
    }

    @Test func customReasonReachesPasswordPrompt() async {
        let h = Harness()
        _ = await collect(h.session().run([Steps.port()], reason: "R"))
        #expect(h.passwords.reasons == ["R"])
        let d = Harness()
        _ = await collect(d.session().run([Steps.port()]))
        #expect(d.passwords.reasons == [RunSession.passwordReason])
    }

    // MARK: Step environment and the passed-check gate

    static let noAutoremove = ["HOMEBREW_NO_AUTOREMOVE": "1"]

    static func withEnvironment(_ step: RunStep, _ environment: [String: String]) -> RunStep {
        RunStep(engine: step.engine, kind: step.kind, operation: step.operation, spec: step.spec, title: step.title,
                requiresAllEarlier: step.requiresAllEarlier, userEnvironment: environment)
    }

    static func mark(_ name: String = "jq") -> RunStep {
        RunStep(engine: .homebrew, operation: .markRequested,
                spec: CommandSpec(executable: URL(fileURLWithPath: Steps.brewPath),
                                  arguments: ["tab", "--installed-on-request", name], needsRoot: false),
                title: "Mark \(name)", requiresPassedCheck: true)
    }

    @Test func userStepGetsItsEnvironmentOnTopOfTheBase() async throws {
        let h = Harness()
        _ = await collect(h.session().run([Self.withEnvironment(Steps.remove("jq"), Self.noAutoremove), Steps.formula()]))
        let calls = h.runner.streamedCalls
        #expect(calls.count == 2)
        #expect(calls.first?.environment == Self.base.merging(Self.noAutoremove) { $1 })
        #expect(calls.last?.environment == nil)  // no variables of its own: the runner's base environment
    }

    @Test func caskStepGetsItsEnvironmentWithTheAskpassOnes() async throws {
        let h = Harness()
        _ = await collect(h.session().run([Self.withEnvironment(Steps.cask("firefox"), Self.noAutoremove)]))
        let call = try #require(h.runner.streamedCalls.first)
        let server = try #require(h.servers.first)
        #expect(call.environment == Self.base.merging(Self.noAutoremove) { $1 }.merging(server.environment) { $1 })
    }

    @Test func stepEnvironmentNeverReachesSudoOrTheHelper() async throws {
        let h = Harness()
        let mas = Self.withEnvironment(Steps.mas(), ["EXTRA": "1"])
        let port = Self.withEnvironment(Steps.port(), ["EXTRA": "1"])
        _ = await collect(h.session().run([mas, port]))
        let sudo = try #require(h.runner.streamedCalls.first { $0.executable.path == "/usr/bin/sudo" })
        #expect(sudo.environment?["EXTRA"] == nil)
        #expect(h.helper.runCalls.count == 1)
        #expect(!h.runner.calls.contains { $0.environment?["EXTRA"] != nil })
    }

    @Test func passedCheckGateSkipsAfterAFailedCheck() async {
        let h = Harness()
        let probe = VerifierProbe(missing: ["jq"])
        let events = await collect(h.session().run([Steps.check(["jq"]), Self.mark()], reason: "R",
                                                   verify: probe.verify))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        #expect(h.runner.calls.isEmpty)
    }

    @Test func passedCheckGateRunsAfterAFailedRemoval() async {
        // The check passed, so the target has the packages: a failed removal doesn't stop the marks.
        let h = Harness()
        h.runner.respond([Steps.brewPath, "uninstall", "--formula", "jq"], code: 1)
        let steps = [Steps.check(["jq"]), Steps.remove("jq"), Self.mark()]
        let events = await collect(h.session().run(steps, reason: "R", verify: VerifierProbe().verify))
        #expect(events.contains(.finished(1, 1)))
        #expect(events.contains(.finished(2, 0)))
    }

    @Test func passedCheckGateNeedsACheck() async {
        let h = Harness()
        let events = await collect(h.session().run([Steps.formula(), Self.mark()]))
        #expect(events.contains(.finished(0, 0)))
        #expect(!events.contains(.started(1)))
    }

    @Test func emptyCheckFails() async {
        let h = Harness()
        let probe = VerifierProbe()
        let events = await collect(h.session().run([Steps.check([]), Steps.remove("jq")], reason: "R",
                                                   verify: probe.verify))
        #expect(events.contains(.finished(0, 1)))
        #expect(!events.contains(.started(1)))
        #expect(probe.asked.isEmpty)
    }

    @Test func checkPlaceholderFailsClosed() {
        #expect(Steps.check().spec.executable.path == "/usr/bin/false")
    }
}
