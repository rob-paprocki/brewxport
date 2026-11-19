import Foundation
import os
import BrewxPortCore
import BrewxPortRun
import Synchronization

let helperLog = Logger(subsystem: "com.brewxport.helper", category: "helper")

/// The only environment `port` gets as root.
let portEnvironment = ["PATH": "/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

/// One root run at a time across every connection. A second request is refused, not queued.
final class RunGate: Sendable {
    private let busy = Mutex(false)

    func tryEnter() -> Bool {
        busy.withLock { busy in
            if busy { return false }
            busy = true
            return true
        }
    }

    func leave() { busy.withLock { $0 = false } }
}

/// The app's exported `BrewxPortHelperClientProtocol` proxy. NSXPC proxies can be messaged from any thread.
struct ClientSink: @unchecked Sendable {
    let proxy: BrewxPortHelperClientProtocol

    func send(_ event: OutputEvent) {
        switch event {
        case .stdout(let line): proxy.output(line: line, isError: false)
        case .stderr(let line): proxy.output(line: line, isError: true)
        }
    }
}

/// One per accepted connection. Every XPC argument is hostile until the checks in `refusal` pass.
final class HelperService: NSObject, BrewxPortHelperProtocol, Sendable {
    private struct State {
        var sink: ClientSink?
        var run: Task<Void, Never>?
        var invalidated = false
    }

    private let peer: pid_t
    private let rightReady: Bool
    private let gate: RunGate
    private let state: Mutex<State>

    init(peer: pid_t, rightReady: Bool, gate: RunGate, sink: ClientSink?) {
        self.peer = peer
        self.rightReady = rightReady
        self.gate = gate
        self.state = Mutex(State(sink: sink))
    }

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(brewxPortHelperVersion)
    }

    func runPort(authorization: Data, arguments: [String], reply: @escaping @Sendable (Int32, String?) -> Void) {
        guard gate.tryEnter() else {
            helperLog.notice("pid \(self.peer): refused, another run is in progress")
            reply(-1, "Another MacPorts command is already running. Try again when it finishes.")
            return
        }
        if let refusal = refusal(authorization: authorization, arguments: arguments) {
            gate.leave()
            reply(-1, refusal)
            return
        }
        helperLog.notice("pid \(self.peer): running port \(arguments.joined(separator: " "), privacy: .public)")
        let task = Task { [self] in
            let (code, error) = await run(arguments)
            // Open the gate before replying: the app sends its next port step as soon as the reply arrives, and
            // must not be told another run is in progress.
            gate.leave()
            helperLog.notice("pid \(self.peer): port finished, exit \(code), \(error ?? "no error", privacy: .public)")
            reply(code, error)
        }
        // If the app went away before the task was recorded, cancel it straight away.
        let cancelNow = state.withLock { s in
            s.run = task
            return s.invalidated
        }
        if cancelNow { task.cancel() }
    }

    /// The connection is gone: kill the running `port` (its whole process group) and drop the client proxy.
    func connectionInvalidated() {
        let run = state.withLock { s in
            s.invalidated = true
            s.sink = nil
            return s.run
        }
        if let run {
            helperLog.notice("pid \(self.peer): connection closed, cancelling the run")
            run.cancel()
        }
    }

    /// Authorization first, on every call, then argv, then the executable. Nil means go.
    private func refusal(authorization: Data, arguments: [String]) -> String? {
        guard rightReady else {
            helperLog.error("pid \(self.peer): refused, the \(brewxPortRunRight, privacy: .public) right isn't installed")
            return "The helper couldn't set up its authorization right. Quit and reopen BrewxPort, then click Check again."
        }
        do {
            try HelperAuthorization.authorize(externalForm: authorization) { detail in
                helperLog.error("pid \(self.peer): not authorized: \(detail, privacy: .public)")
            }
            try HelperRequestValidator.validate(arguments: arguments)
            try HelperRequestValidator.validateInstallation(
                attributes: HelperRequestValidator.fileSystemAttributes,
                readHead: HelperRequestValidator.readScriptHead)
            return nil
        } catch let error as HelperError {
            helperLog.error("pid \(self.peer): refused: \(error.message, privacy: .public)")
            return error.message
        } catch {
            helperLog.error("pid \(self.peer): refused: \(String(describing: error), privacy: .public)")
            return "Refused: \(error.localizedDescription)"
        }
    }

    /// Runs `port` with a bare environment, cwd `/` (so a bare name can't resolve to a Portfile directory) and
    /// stdin from /dev/null. No timeout: a source build can take hours. Cancellation ends it.
    private func run(_ arguments: [String]) async -> (Int32, String?) {
        let options = RunOptions(environment: portEnvironment, workingDirectory: "/")
        do {
            let code = try await ProcessRunner().stream(
                URL(fileURLWithPath: HelperRequestValidator.portPath), arguments, options: options
            ) { [self] event in
                state.withLock { $0.sink }?.send(event)
            }
            return (code, nil)
        } catch is CancellationError {
            return (-1, "The run was stopped because BrewxPort disconnected.")
        } catch {
            return (-1, "Couldn't run port: \(error)")
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    /// Nil refuses every connection (missing, blank or unparsable `BrewxPortClientRequirement`).
    private let requirement: String?
    private let rightReady: Bool
    private let gate = RunGate()

    init(requirement: String?, rightReady: Bool) {
        self.requirement = requirement
        self.rightReady = rightReady
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard let requirement else {
            helperLog.error("refused pid \(pid): no usable \(brewxPortClientRequirementKey, privacy: .public) in Info.plist")
            return false
        }
        // The listener already enforces this; setting it per connection too costs nothing.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = HelperInterfaces.helper()
        connection.remoteObjectInterface = HelperInterfaces.client()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            helperLog.error("pid \(pid): client proxy error: \(error.localizedDescription, privacy: .public)")
        } as? BrewxPortHelperClientProtocol
        let service = HelperService(peer: pid, rightReady: rightReady, gate: gate, sink: proxy.map(ClientSink.init))
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in service?.connectionInvalidated() }
        connection.interruptionHandler = { [weak service] in service?.connectionInvalidated() }
        helperLog.notice("accepted pid \(pid), uid \(connection.effectiveUserIdentifier)")
        connection.resume()
        return true
    }
}
