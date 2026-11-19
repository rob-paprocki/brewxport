import Foundation
import BrewxPortCore
import Synchronization

/// Asks the user for the administrator password.
public protocol PasswordProviding: Sendable {
    /// Nil means the user cancelled. The session takes ownership of the buffer and wipes it when the run ends.
    func password(reason: String) async -> SecretBuffer?
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

/// The askpass server as RunSession uses it, so tests can count `stop()`.
protocol AskpassServing: AnyObject, Sendable {
    var environment: [String: String] { get }
    func stop()
}

extension AskpassServer: AskpassServing {}

typealias AskpassServerFactory = @Sendable (_ secret: SecretBuffer, _ askpassPath: String) throws -> any AskpassServing

/// Runs a list of steps (an "Update all") with at most one password prompt.
///
/// 1. If any step's route isn't `.user`, it first checks that the user is in the admin group (a standard user gets
///    `.privilegeUnavailable` and no prompt), then emits `.needsPassword` and asks once.
/// 2. Before the first step it checks the password: helper steps through `helper.authorize`, askpass steps through
///    `/usr/bin/sudo -A -k -v` with the askpass server. A wrong password gives `.passwordRejected` and nothing runs.
///    The askpass server answers each sudo once, so a wrong password fails at once instead of after sudo's retries.
/// 3. It runs the steps in order through `spec.launchCommand()`. A failed step doesn't stop the rest.
/// 4. On every exit (done, rejected, cancelled) it wipes the password, stops the askpass server and calls
///    `helper.endAuthorization()`, then emits `.done`.
///
/// Cancelling, through `cancel()` or by dropping the stream (cancelling the task that iterates it), kills the
/// current child, runs nothing further, cleans up as above, and emits `.cancelled` then `.done` (a dropped stream
/// doesn't see them). The password is never put in an environment, an argument, an event or an error.
public final class RunSession: Sendable {
    static let sudoPath = "/usr/bin/sudo"
    static let verifyArguments = ["-A", "-k", "-v"]
    static let passwordReason = "BrewxPort needs an administrator password to install these updates."

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

    /// `reason` is what the password prompt says the password is for.
    public func run(_ steps: [RunStep], reason: String) -> AsyncStream<RunEvent> {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let id = UUID()
        // Created under the lock, so the task's own removal can't run before it's recorded.
        let task = runs.withLock { runs in
            let task = Task { [self] in
                await execute(steps, reason: reason) { continuation.yield($0) }
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

    private func execute(_ steps: [RunStep], reason: String,
                         emit: @escaping @Sendable (RunEvent) -> Void) async {
        var state = State()
        let ending = await perform(steps, reason: reason, &state, emit)
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

    private func perform(_ steps: [RunStep], reason: String, _ state: inout State,
                         _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending {
        let routes = steps.map(RunRouting.route(for:))
        if routes.contains(where: { $0 != .user }) {
            // Checked before prompting: authd can't tell a standard user's right password from a wrong one.
            if isAdministrator() == false { return .unavailable(Self.notAnAdministrator) }
            if let early = await acquireAndVerify(routes, reason: reason, &state, emit) { return early }
        }
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            emit(.started(index))
            let code: Int32
            do {
                code = try await run(step, index: index, route: routes[index], &state, emit)
            } catch is CancellationError {
                return .cancelled
            } catch {
                emit(.output(index, .stderr(Self.describe(error))))
                code = -1
            }
            // A step that returned an exit code finished, even if the run was cancelled meanwhile. Only a step that
            // threw CancellationError is left open; the check at the top of the loop stops the next one.
            emit(.finished(index, code))
        }
        return .done
    }

    /// Asks once, then checks the password. Returns an ending when the run must stop before its first step.
    private func acquireAndVerify(_ routes: [RunRoute], reason: String, _ state: inout State,
                                  _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending? {
        emit(.needsPassword)
        guard let secret = await passwords.password(reason: reason) else { return .cancelled }
        state.secret = secret
        if Task.isCancelled { return .cancelled }

        if routes.contains(.helper) {
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

    private func run(_ step: RunStep, index: Int, route: RunRoute, _ state: inout State,
                     _ emit: @escaping @Sendable (RunEvent) -> Void) async throws -> Int32 {
        let onOutput: @Sendable (OutputEvent) -> Void = { emit(.output(index, $0)) }
        let launch = step.spec.launchCommand(host: host)
        switch route {
        case .user:
            return try await runner.stream(launch.executable, launch.arguments, options: RunOptions(),
                                           onOutput: onOutput)
        case .userWithAskpass, .sudoAskpass:
            guard state.askpassFailure == nil, let server = state.server else {
                throw StepFailure(message: state.askpassFailure ?? "BrewxPort couldn't pass the password to sudo.")
            }
            let options = RunOptions(environment: askpassEnvironment(server))
            if route == .userWithAskpass {
                return try await runner.stream(launch.executable, launch.arguments, options: options,
                                               onOutput: onOutput)
            }
            return try await runner.stream(URL(fileURLWithPath: Self.sudoPath),
                                           ["-A", launch.executable.path] + launch.arguments,
                                           options: options, onOutput: onOutput)
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

    private func askpassEnvironment(_ server: any AskpassServing) -> [String: String] {
        baseEnvironment.merging(server.environment) { $1 }
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
