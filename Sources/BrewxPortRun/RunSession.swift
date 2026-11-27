import Foundation
import BrewxPortCore
import Synchronization

/// Asks the user for the administrator password.
public protocol PasswordProviding: Sendable {
    /// Nil means the user cancelled. The session takes ownership of the buffer and wipes it when the run ends, or as
    /// soon as it's rejected. `previousAttemptFailed` is true when the same run's last password was rejected.
    func password(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer?
}

/// The app's side of BrewxPortHelper. Task 11 provides the live one (XPC plus `AppAuthorization`).
public protocol HelperConnecting: Sendable {
    /// Acquires `brewxPortRunRight` with the password and returns the authorization's external form. Replaces any
    /// authorization acquired earlier. A wrong password throws `HelperError.notAuthorized`.
    func authorize(_ secret: SecretBuffer) async throws -> Data
    /// Runs `port` as root with `arguments` (the helper picks the executable). Throws `HelperError.notAuthorized`
    /// when the helper refuses the authorization, for example because the right's timeout ran out. Cancelling the
    /// calling task must stop the run.
    func runPort(authorization: Data, arguments: [String],
                 onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32
    /// Sets up one package manager as root through the helper. Same authorization, cancellation and
    /// `HelperError.notAuthorized` rules as `runPort`.
    func setUpEngine(authorization: Data, target: SetupTarget,
                     onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32
    /// Frees the authorization and destroys its rights. Idempotent, and a no-op when nothing is held. Called at
    /// the end of every run, including a cancelled one, so it must not give up because its task is cancelled.
    func endAuthorization() async
}

public enum RunEvent: Sendable, Equatable {
    /// The run is about to ask for the administrator password.
    case needsPassword
    /// The password didn't work. Nothing ran.
    case passwordRejected
    /// Root work can't happen for a reason other than the password (the account isn't an administrator, sudo
    /// couldn't run askpass, authd failed). The text says which. Nothing ran.
    case privilegeUnavailable(String)
    case started(Int)
    case output(Int, OutputEvent)
    /// The step's exit code. -1 when it couldn't run at all; an `.output` stderr line before it says why.
    case finished(Int, Int32)
    /// The user cancelled the password prompt, or the run was cancelled. Nothing more runs.
    case cancelled
    /// Always the last event.
    case done
}

/// Answers a check step: given packages that should now be installed, returns the ones that are missing.
public typealias InstalledVerifier = @Sendable ([PackageRef]) async -> [PackageRef]

/// The askpass server as RunSession uses it, so tests can count `stop()`.
protocol AskpassServing: AnyObject, Sendable {
    var environment: [String: String] { get }
    func stop()
}

extension AskpassServer: AskpassServing {}

typealias AskpassServerFactory = @Sendable (_ secret: SecretBuffer, _ askpassPath: String) throws -> any AskpassServing

/// Runs a list of steps (an "Update all") with one password for the whole run.
///
/// 1. If any step's route isn't `.user`, it first checks that the user is in the admin group (a standard user gets
///    `.privilegeUnavailable` and no prompt), then emits `.needsPassword` once and asks.
/// 2. Before the first step it checks the password: helper steps through `helper.authorize`, askpass steps through
///    `/usr/bin/sudo -A -k -v` with the askpass server. A wrong password is wiped, its askpass server stopped, and the
///    password asked for again (`previousAttemptFailed`), up to `passwordAttempts` times in all, like sudo. After the
///    last wrong one it gives `.passwordRejected` and nothing runs. Nothing runs until a password is verified; a
///    cancel at any ask ends the run, and a failure other than the password isn't retried. The askpass server answers
///    each sudo once, so a wrong password fails at once instead of after sudo's retries.
/// 3. It runs the steps in order through `spec.launchCommand()`. A failed step doesn't stop the rest, but it does
///    stop a later step that `dependsOnPrevious` (right after it) or `requiresAllEarlier` (only within its
///    `gateGroup` when it has one). A check step
///    (`verifyInstalled`) launches nothing: the run's verifier says which packages are missing. A step that
///    `requiresPassedCheck` runs only after a check passed and none failed. A step's `userEnvironment` is added only
///    on the user routes. A command's own environment and folder (`CommandSpec.environment`, `workingDirectory`) are
///    used only for a language engine's step on `.user`, never for a system engine's, nor with askpass, sudo or the
///    helper. So is its confirmation (`CommandSpec.confirmation`): started after the command exits 0, with the same
///    environment and folder, and the step fails (exit 1) unless it exits 0 too, with the confirmation's words or a
///    plain reason (`unconfirmed`), and unless its stdout passes the confirmation's check when it has one
///    (`ConfirmationCheck`: Mint's list shows the change), with the check's reason. Every output line of a language
///    engine's step, a confirmation's included, loses URL credentials (`CredentialScrubber`) before an event carries
///    it; the system engines' output is passed on as it came.
/// 4. On every exit (done, rejected, cancelled) it wipes the password, stops the askpass server and calls
///    `helper.endAuthorization()`, then emits `.done`.
///
/// Cancelling, through `cancel()` or by dropping the stream (cancelling the task that iterates it), kills the
/// current child, runs nothing further, cleans up as above, and emits `.cancelled` then `.done` (a dropped stream
/// doesn't see them). The password is never put in an environment, an argument, an event or an error.
public final class RunSession: Sendable {
    static let sudoPath = "/usr/bin/sudo"
    static let verifyArguments = ["-A", "-k", "-v"]
    /// The `.sudoAskpass` route's options before the command: askpass, and no cached credential used or kept (R35).
    static let sudoArguments = ["-A", "-k"]
    /// How many passwords a run asks for before it gives up, counting the first.
    static let passwordAttempts = 3
    static let passwordReason = "BrewxPort needs an administrator password to install these updates."
    /// The step's reason when its confirmation (`CommandSpec.confirmation`) failed without saying why.
    static let unconfirmed = "The command finished, but BrewxPort couldn't confirm that it worked."

    private let runner: any CommandRunning
    private let helper: any HelperConnecting
    private let passwords: any PasswordProviding
    private let askpassPath: String
    private let host: Arch
    private let baseEnvironment: [String: String]
    private let makeAskpassServer: AskpassServerFactory
    private let isAdministrator: AdminCheck
    private let runs = Mutex<[UUID: Task<Void, Never>]>([:])

    /// `askpassPath` is the bundled `brewxport-askpass`. `askpassRequirement` is the code-signing requirement it must
    /// satisfy (`CodeIdentity.requirement(identifier: CodeIdentity.askpassIdentifier, team:)`); the app always
    /// passes one. Nil skips that check.
    public convenience init(runner: CommandRunning, helper: HelperConnecting, passwords: PasswordProviding,
                            askpassPath: String, askpassRequirement: String?) {
        self.init(runner: runner, helper: helper, passwords: passwords, askpassPath: askpassPath,
                  host: .current, baseEnvironment: ProcessRunner.baseEnvironment,
                  isAdministrator: AdminMembership.currentUserIsAdmin,
                  askpassRequirement: askpassRequirement)
    }

    /// `host` and `makeAskpassServer` exist for tests. `baseEnvironment` must be the runner's own base
    /// environment: askpass steps get it plus the askpass variables. Without `makeAskpassServer`, each run makes a
    /// real `AskpassServer` with `askpassRequirement`.
    /// `isAdministrator` is `AdminMembership.currentUserIsAdmin` in production; tests pass a fake. It has no
    /// default so no test depends on the account that runs it.
    init(runner: CommandRunning, helper: HelperConnecting, passwords: PasswordProviding, askpassPath: String,
         host: Arch, baseEnvironment: [String: String], isAdministrator: @escaping AdminCheck,
         askpassRequirement: String? = nil, makeAskpassServer: AskpassServerFactory? = nil) {
        self.isAdministrator = isAdministrator
        self.runner = runner
        self.helper = helper
        self.passwords = passwords
        self.askpassPath = askpassPath
        self.host = host
        self.baseEnvironment = baseEnvironment
        self.makeAskpassServer = makeAskpassServer ?? { secret, path in
            try AskpassServer(secret: secret, askpassPath: path, peerRequirement: askpassRequirement)
        }
    }

    public func run(_ steps: [RunStep]) -> AsyncStream<RunEvent> {
        run(steps, reason: Self.passwordReason)
    }

    /// The verifier a run gets when none is passed: it reports every package missing, so a check step fails.
    public static let failClosed: InstalledVerifier = { $0 }

    public func run(_ steps: [RunStep], reason: String) -> AsyncStream<RunEvent> {
        run(steps, reason: reason, verify: Self.failClosed)
    }

    /// `reason` is what the password prompt says the password is for. `verify` answers the check steps.
    public func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let id = UUID()
        // Created under the lock, so the task's own removal can't run before it's recorded.
        let task = runs.withLock { runs in
            let task = Task { [self] in
                await execute(steps, reason: reason, verify: verify) { continuation.yield($0) }
                continuation.finish()
                removeRun(id)
            }
            runs[id] = task
            return task
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Cancels every run in progress. Each still emits `.cancelled` and `.done`.
    public func cancel() {
        for task in runs.withLock({ Array($0.values) }) { task.cancel() }
    }

    private func removeRun(_ id: UUID) {
        _ = runs.withLock { $0.removeValue(forKey: id) }
    }

    // MARK: One run

    private enum Ending { case done, rejected, unavailable(String), cancelled }

    /// What the run holds between steps. Only the run's own task touches it.
    private struct State {
        var secret: SecretBuffer?
        var server: (any AskpassServing)?
        var authorization: Data?
        /// Why helper steps can't run, when the helper failed for a reason other than the password.
        var helperFailure: String?
        /// Why askpass steps can't run, when the server or the sudo check failed for a reason other than the
        /// password.
        var askpassFailure: String?
    }

    private struct StepFailure: Error { let message: String }

    private func execute(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier,
                         emit: @escaping @Sendable (RunEvent) -> Void) async {
        var state = State()
        let ending = await perform(steps, reason: reason, verify: verify, &state, emit)
        state.secret?.wipe()
        state.server?.stop()
        await helper.endAuthorization()
        switch ending {
        case .done: break
        case .rejected: emit(.passwordRejected)
        case .unavailable(let reason): emit(.privilegeUnavailable(reason))
        case .cancelled: emit(.cancelled)
        }
        emit(.done)
    }

    private func perform(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier,
                         _ state: inout State, _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending {
        let routes = steps.map(RunRouting.route(for:))
        if routes.contains(where: { $0 != .user }) {
            // Checked before prompting: authd can't tell a standard user's right password from a wrong one.
            if isAdministrator() == false { return .unavailable(Self.notAnAdministrator) }
            if let early = await acquireAndVerify(routes, reason: reason, &state, emit) { return early }
        }
        // Whether the step before the current one finished with exit code 0, and whether every earlier step did. A
        // skipped step counts as not.
        var previousSucceeded = true
        var allEarlierSucceeded = true
        // The gate groups with a step that failed or was skipped.
        var failedGroups: Set<String> = []
        // Nil until a check step runs; false once any check step failed or was skipped.
        var checksPassed: Bool?
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            let earlierFailed = step.gateGroup.map { failedGroups.contains($0) } ?? !allEarlierSucceeded
            if (step.dependsOnPrevious && !previousSucceeded) || (step.requiresAllEarlier && earlierFailed)
                || (step.requiresPassedCheck && checksPassed != true) {
                // Left unstarted, which the UI shows as skipped. Later steps that depend on it are skipped too.
                previousSucceeded = false
                allEarlierSucceeded = false
                if let group = step.gateGroup { failedGroups.insert(group) }
                if step.verifyInstalled != nil { checksPassed = false }
                continue
            }
            emit(.started(index))
            let stepEmit = step.engine.isLanguage ? Self.withoutCredentials(emit) : emit
            let code: Int32
            do {
                if let refs = step.verifyInstalled {
                    code = try await check(refs, on: step.engine, index: index, verify: verify, stepEmit)
                } else {
                    code = try await run(step, index: index, route: routes[index], &state, stepEmit)
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                stepEmit(.output(index, .stderr(Self.describe(error))))
                code = -1
            }
            // A step that returned an exit code finished, even if the run was cancelled meanwhile. Only a step that
            // threw CancellationError is left open; the check at the top of the loop stops the next one.
            emit(.finished(index, code))
            previousSucceeded = code == 0
            if code != 0 {
                allEarlierSucceeded = false
                if let group = step.gateGroup { failedGroups.insert(group) }
            }
            if step.verifyInstalled != nil { checksPassed = code == 0 && checksPassed != false }
        }
        return .done
    }

    /// Asks for the password and checks it, asking again after a wrong one, up to `passwordAttempts` in all. Returns
    /// an ending when the run must stop before its first step.
    private func acquireAndVerify(_ routes: [RunRoute], reason: String, _ state: inout State,
                                  _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending? {
        emit(.needsPassword)
        for attempt in 1...Self.passwordAttempts {
            let ending = await verifyOnce(routes, reason: reason, previousAttemptFailed: attempt > 1, &state)
            guard case .rejected? = ending, attempt < Self.passwordAttempts else { return ending }
            // Nothing of the wrong password outlives its attempt: the buffer, the server that held it, and anything
            // the attempt found out.
            state.secret?.wipe()
            state.server?.stop()
            state = State()
            if Task.isCancelled { return .cancelled }
        }
        return .rejected
    }

    /// One ask and its check.
    private func verifyOnce(_ routes: [RunRoute], reason: String, previousAttemptFailed: Bool,
                            _ state: inout State) async -> Ending? {
        guard let secret = await passwords.password(reason: reason, previousAttemptFailed: previousAttemptFailed)
        else { return .cancelled }
        state.secret = secret
        if Task.isCancelled { return .cancelled }

        if routes.contains(where: { $0 == .helper || $0 == .helperSetup }) {
            do {
                state.authorization = try await helper.authorize(secret)
            } catch HelperError.notAuthorized {
                return .rejected
            } catch AppAuthorizationError.failed(let status) {
                // Not -60005/-60007 (those are a wrong password): authd itself failed, so nothing root can run.
                return .unavailable("macOS didn't grant administrator rights (authorization error \(status)).")
            } catch is CancellationError {
                return .cancelled
            } catch {
                state.helperFailure = "BrewxPort's helper isn't available: \(Self.describe(error))"
            }
            if Task.isCancelled { return .cancelled }
        }

        if routes.contains(where: { $0 == .sudoAskpass || $0 == .userWithAskpass }) {
            do {
                let server = try makeAskpassServer(secret, askpassPath)
                state.server = server
                let result = try await runner.run(
                    URL(fileURLWithPath: Self.sudoPath), Self.verifyArguments,
                    options: RunOptions(environment: askpassEnvironment(server), timeout: BrewxPortTimeouts.engineQuery))
                if result.exitCode != 0 {
                    if let reason = Self.privilegeUnavailable(sudoStderr: result.stderr) { return .unavailable(reason) }
                    return .rejected
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                state.askpassFailure = "BrewxPort couldn't pass the password to sudo: \(Self.describe(error))"
            }
            if Task.isCancelled { return .cancelled }
        }
        return nil
    }

    /// A check step: 0 when the verifier finds nothing missing, 1 (with one stderr line naming the missing packages)
    /// otherwise. A check over no packages fails: it would pass without checking anything. A run cancelled while the
    /// verifier works leaves the step open, whatever the verifier said.
    private func check(_ refs: [PackageRef], on engine: EngineID, index: Int, verify: InstalledVerifier,
                       _ emit: @escaping @Sendable (RunEvent) -> Void) async throws -> Int32 {
        guard !refs.isEmpty else {
            emit(.output(index, .stderr("There was nothing to check on \(engine.displayName).")))
            return 1
        }
        let missing = await verify(refs)
        try Task.checkCancellation()
        guard !missing.isEmpty else { return 0 }
        let names = missing.map(\.name).joined(separator: ", ")
        emit(.output(index, .stderr("Not found on \(engine.displayName): \(names)")))
        return 1
    }

    private func run(_ step: RunStep, index: Int, route: RunRoute, _ state: inout State,
                     _ emit: @escaping @Sendable (RunEvent) -> Void) async throws -> Int32 {
        let onOutput: @Sendable (OutputEvent) -> Void = { emit(.output(index, $0)) }
        let launch = step.spec.launchCommand(host: host)
        switch route {
        case .user:
            // A language engine's command brings its whole environment and its folder (`CommandSpec.environment`);
            // the step's own variables go on top. Neither, and it's the runner's own base environment. A system
            // engine's spec never brings either.
            let environment = step.engine.isLanguage ? step.spec.environment : nil
            let folder = step.engine.isLanguage ? step.spec.workingDirectory : nil
            let options: RunOptions
            if step.userEnvironment.isEmpty, environment == nil {
                options = RunOptions(workingDirectory: folder)
            } else {
                options = RunOptions(environment: (environment ?? baseEnvironment).merging(step.userEnvironment) { $1 },
                                     workingDirectory: folder)
            }
            guard step.engine == .homebrew, step.operation == .remove else {
                let code = try await runner.stream(launch.executable, launch.arguments, options: options,
                                                   onOutput: onOutput)
                guard code == 0, step.engine.isLanguage, let confirmation = step.spec.confirmation else { return code }
                // The command exited 0, which for some tools doesn't mean it did anything (RubyGems' uninstall of a
                // default gem): its confirmation says, in the same environment and folder. Its words follow the
                // command's own in the step's output, through the same credential scrub; when it fails without a
                // word, the step still gets a plain one. A confirmation that exits 0 whatever it finds (`mint list`)
                // has a check its stdout must also pass, whose reason is the step's last line when it doesn't.
                let saidWhy = Mutex(false)
                let printed = Mutex<[String]>([])
                let confirmed = try await runner.stream(confirmation.executable, confirmation.arguments,
                                                        options: options) { event in
                    switch event {
                    case .stderr(let text) where !text.allSatisfy(\.isWhitespace): saidWhy.withLock { $0 = true }
                    case .stdout(let line) where confirmation.check != nil: printed.withLock { $0.append(line) }
                    default: break
                    }
                    onOutput(event)
                }
                if confirmed == 0, let check = confirmation.check,
                   let reason = check.failure(in: printed.withLock { $0 }.joined(separator: "\n")) {
                    onOutput(.stderr(reason))
                    return 1
                }
                guard confirmed != 0 else { return 0 }
                if !saidWhy.withLock({ $0 }) { onOutput(.stderr(Self.unconfirmed)) }
                return 1
            }
            let errors = Mutex<[String]>([])
            let code = try await runner.stream(launch.executable, launch.arguments, options: options) { event in
                if case .stderr(let text) = event { errors.withLock { $0.append(text) } }
                onOutput(event)
            }
            guard code == 1,
                  let names = Self.alreadyRemoved(stderr: errors.withLock { $0 }.joined(separator: "\n"),
                                                  arguments: step.spec.arguments)
            else { return code }
            for name in names { emit(.output(index, .stdout("\(name) was already removed."))) }
            return 0
        case .userWithAskpass, .sudoAskpass:
            guard state.askpassFailure == nil, let server = state.server else {
                throw StepFailure(message: state.askpassFailure ?? "BrewxPort couldn't pass the password to sudo.")
            }
            if route == .userWithAskpass {
                // The step's own variables never override the askpass ones.
                let environment = baseEnvironment.merging(step.userEnvironment) { $1 }
                    .merging(server.environment) { $1 }
                return try await runner.stream(launch.executable, launch.arguments,
                                               options: RunOptions(environment: environment), onOutput: onOutput)
            }
            // sudo: never the step's own variables. `-k` (R35): sudo neither uses nor writes a cached credential, so
            // no ticket keyed to BrewxPort outlives the step for a later child to reuse with `sudo -n`. Askpass
            // answers each sudo once. No `sudo -K` at the end: it would clear the person's own Terminal sessions.
            let options = RunOptions(environment: askpassEnvironment(server))
            return try await runner.stream(URL(fileURLWithPath: Self.sudoPath),
                                           Self.sudoArguments + [launch.executable.path] + launch.arguments,
                                           options: options, onOutput: onOutput)
        case .helperSetup:
            guard let target = step.setupTarget else { throw StepFailure(message: "This step has no engine to set up.") }
            guard let authorization = state.authorization, let secret = state.secret else {
                throw StepFailure(message: state.helperFailure ?? "BrewxPort's helper isn't available.")
            }
            do {
                return try await helper.setUpEngine(authorization: authorization, target: target, onOutput: onOutput)
            } catch HelperError.notAuthorized {
                let fresh = try await helper.authorize(secret)
                state.authorization = fresh
                return try await helper.setUpEngine(authorization: fresh, target: target, onOutput: onOutput)
            }
        case .helper:
            guard let authorization = state.authorization, let secret = state.secret else {
                throw StepFailure(message: state.helperFailure ?? "BrewxPort's helper isn't available.")
            }
            do {
                return try await helper.runPort(authorization: authorization, arguments: step.spec.arguments,
                                                onOutput: onOutput)
            } catch HelperError.notAuthorized {
                // The right's timeout ran out during a long run: authorize again with the held password, once.
                let fresh = try await helper.authorize(secret)
                state.authorization = fresh
                return try await helper.runPort(authorization: fresh, arguments: step.spec.arguments,
                                                onOutput: onOutput)
            }
        }
    }

    /// The packages Homebrew says have no keg, when that is the only error `brew uninstall` printed (Apple silicon
    /// `/opt/homebrew/Cellar/<name>`, Intel `/usr/local/Cellar/<name>`). Nil when any other `Error:` line is there,
    /// or none is a "No such keg", or the step removes more than one package or a different one from the missing
    /// keg, so the step keeps its failure.
    static func alreadyRemoved(stderr: String, arguments: [String]) -> [String]? {
        // Only a step that removes exactly one package: `brew uninstall a b` checks every keg first and removes
        // nothing when one is missing, so the others would still be installed.
        let packages = arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard packages.count == 1, let package = packages.first?.split(separator: "/").last else { return nil }
        var names: [String] = []
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("Error:") else { continue }
            let prefix = "Error: No such keg: "
            guard text.hasPrefix(prefix) else { return nil }
            let path = text.dropFirst(prefix.count)
            guard path.hasPrefix("/opt/homebrew/Cellar/") || path.hasPrefix("/usr/local/Cellar/") else { return nil }
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard !name.isEmpty, name != "Cellar" else { return nil }
            names.append(name)
        }
        return names == [String(package)] ? names : nil
    }

    private func askpassEnvironment(_ server: any AskpassServing) -> [String: String] {
        baseEnvironment.merging(server.environment) { $1 }
    }

    /// `emit`, with URL credentials taken out of every output line first (`CredentialScrubber`): what a language
    /// tool prints can name a private index with its token, and every output event reaches the run log, a step's
    /// failure text or a notification.
    static func withoutCredentials(_ emit: @escaping @Sendable (RunEvent) -> Void) -> @Sendable (RunEvent) -> Void {
        { event in
            switch event {
            case .output(let index, .stdout(let line)): emit(.output(index, .stdout(CredentialScrubber.scrub(line))))
            case .output(let index, .stderr(let line)): emit(.output(index, .stderr(CredentialScrubber.scrub(line))))
            default: emit(event)
            }
        }
    }

    static let notAnAdministrator = "This account can't make admin changes. Sign in as an administrator to update."

    /// Why a failed `sudo -A -k -v` wasn't a wrong password, from its stderr, or nil when it was (or might have
    /// been). Checked before treating a failure as a wrong password: a non-administrator who types the right
    /// password gets past PAM first, so authentication lines can come before the sudoers one.
    static func privilegeUnavailable(sudoStderr stderr: String) -> String? {
        let text = stderr.lowercased()
        if text.contains("is not in the sudoers file") || text.contains("may not run sudo") {
            return notAnAdministrator
        }
        let askpassMarkers = ["no askpass program", "unable to run", "unable to execute"]
        if askpassMarkers.contains(where: text.contains) {
            let line = stderr.split(whereSeparator: \.isNewline)
                .first { line in askpassMarkers.contains { line.lowercased().contains($0) } }
                .map { String($0.prefix(300)) } ?? ""
            return "BrewxPort couldn't pass the password to sudo: \(line)"
        }
        return nil
    }

    /// Text for a step's stderr line. None of these errors carries the password.
    static func describe(_ error: Error) -> String {
        switch error {
        case let failure as StepFailure: failure.message
        case let helper as HelperError: helper.message
        case CommandRunnerError.launchFailed(let reason): "Couldn't run the command: \(reason)"
        case CommandRunnerError.timedOut: "The command didn't finish in time."
        case CommandRunnerError.readFailed(let reason): "Couldn't read the command's output: \(reason)"
        case let server as AskpassServerError: "askpass setup failed (\(server))"
        default: String(describing: error)
        }
    }
}
