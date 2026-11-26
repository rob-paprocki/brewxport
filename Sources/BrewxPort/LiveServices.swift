import Foundation
import BrewxPortCore
import BrewxPortRun
import BrewxPortUI

/// The real world: engines at their fixed paths, the helper, and one-password runs. Only a `.live` startup builds
/// these; a development Mac never gets here.
enum LiveServices {
    static let unsignedProblem =
        "This copy of BrewxPort isn't signed by a developer team, so it can't install, update or remove packages."

    @MainActor static func make() -> Services {
        let runner = ProcessRunner()
        let host = Arch.current
        let engines = Engines.make(runner: runner, arch: host)
        let catalog = PackageCatalog(engines: engines, arch: host)
        // One provider: RunSession asks it, and BrewxPortAppModel points it at the run controller.
        let passwords = PromptPasswordProvider()
        var executor: (any RunExecuting)?
        var helper: (any HelperManaging)?
        var setupProblem: String?
        // Both requirements come from this app's own signature. Without a team there's no safe requirement, so
        // nothing privileged is set up at all (fail closed, never a nil requirement).
        if let team = CodeIdentity.ownTeamIdentifier(),
           let helperRequirement = CodeIdentity.requirement(identifier: CodeIdentity.helperIdentifier, team: team),
           let askpassRequirement = CodeIdentity.requirement(identifier: CodeIdentity.askpassIdentifier, team: team) {
            let connection = LiveHelperConnection(helperRequirement: helperRequirement)
            helper = HelperRegistration(service: LiveDaemonService(), connection: connection)
            executor = RunSession(runner: runner, helper: connection, passwords: passwords,
                                  askpassPath: askpassPath, askpassRequirement: askpassRequirement)
        } else {
            setupProblem = unsignedProblem
        }
        let path = loginShellPath(runner)
        return Services(
            engines: engines, catalog: catalog, executor: executor, helper: helper, passwords: passwords,
            isAdministrator: AdminMembership.currentUserIsAdmin, store: DefaultsStore(), path: path,
            fileExists: { FileManager.default.fileExists(atPath: $0) }, host: host, hostInfo: HostInfo.current(),
            cltPresent: { FileManager.default.fileExists(atPath: CommandLineTools.marker) },
            receipts: PkgutilReceipts(runner: runner), setupProblem: setupProblem,
            isDemo: false,
            scheduler: LiveBackgroundScheduler(), notifier: LiveUpdateNotifier(), loginItem: LiveLoginItem(),
            conditions: LiveSystemConditions(),
            // The same login shell the PATH resolver asks; nothing extra is run to find it.
            shellPath: ShellPathEditor(home: FileManager.default.homeDirectoryForCurrentUser, shell: path.loginShell))
    }

    /// The login shell's PATH, asked for once, the first time Installed loads (read-only: the shell prints its PATH).
    /// Falls back to /etc/paths and /etc/paths.d when the shell isn't listed in /etc/shells or doesn't answer.
    static func loginShellPath(_ runner: ProcessRunner) -> LoginShellPath {
        LoginShellPath(runner: runner, shell: LoginShellPath.userShell(), allowedShells: LoginShellPath.allowedShells(),
                       systemPaths: { LoginShellPath.systemPaths() })
    }

    /// The bundled `Contents/MacOS/brewxport-askpass`.
    static var askpassPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/brewxport-askpass").path
    }
}
