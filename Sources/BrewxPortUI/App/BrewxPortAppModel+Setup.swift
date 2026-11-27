import Foundation
import BrewxPortCore
import BrewxPortRun

/// What a "Set Up <name>…" button shows. The views draw this and decide nothing.
public enum SetupButtonState: Equatable {
    /// Nothing to show: the engine is there (or not working, which setup doesn't fix), or can't be set up here.
    case hidden
    /// No button, one line saying why (Homebrew on an Intel Mac).
    case unavailable(note: String)
    case disabled(title: String, help: String)
    case enabled(title: String)
}

/// R30/R31: Homebrew's runtime beside a language engine that's there but read-only.
enum HomebrewRuntimeOffer: Equatable {
    /// Set Up of Homebrew's Ruby or Node is offered.
    case offered
    /// Not offered: npm lives in Homebrew's own prefix without being Homebrew's, so `brew install node` couldn't link.
    case clashes(prefix: String)
}

extension BrewxPortAppModel {
    /// The button for a missing engine's Engines page and its Bundles banner. Also for Cargo whose rustup has no
    /// toolchain (`ownRustup`: its `default stable`, nothing else), and for Homebrew's Ruby or Node beside a read-only
    /// RubyGems or npm (`homebrewRuntimeOffer`).
    public func setupButton(for engine: EngineID) -> SetupButtonState {
        let runtime = homebrewRuntimeOffer(for: engine)
        if case .clashes(let prefix)? = runtime { return .unavailable(note: SetupCopy.homebrewNodeClash(prefix: prefix)) }
        let besideReadOnly = runtime == .offered
        let toolchainOnly = ownRustup(engine) != nil
        guard engineStatuses[engine] == .missing || besideReadOnly || toolchainOnly else { return .hidden }
        guard EngineSetupPlanner.offered(host: services.hostInfo).contains(engine) else {
            return engine == .homebrew ? .unavailable(note: SetupCopy.intelHomebrew) : .hidden
        }
        // A rustup that's already there needs neither Homebrew nor MacPorts.
        let route = toolchainOnly ? nil : EngineSetupPlanner.languageRoute(engine, statuses: engineStatuses)
        if route == .homebrewOnly {
            return .unavailable(note: SetupCopy.homebrewOnly(engine, appleSilicon: services.hostInfo.appleSilicon))
        }
        let title = besideReadOnly ? SetupCopy.homebrewRuntimeButton(engine) : SetupCopy.buttonTitle(engine)
        if services.isDemo { return .disabled(title: title, help: SetupCopy.demoHelp) }
        let needsAdministrator: Bool
        switch route {
        case .needsManager?:
            return .disabled(title: title,
                             help: SetupCopy.languageNeedsManager(engine, appleSilicon: services.hostInfo.appleSilicon))
        case .homebrew?:
            // A Homebrew formula installs as the user: any account that can run Homebrew can.
            needsAdministrator = false
        case .macports?, .homebrewOnly?:
            needsAdministrator = true
        case nil:
            // A system package manager; or Cargo's toolchain with its own rustup, as the user.
            needsAdministrator = !engine.isLanguage
        }
        if needsAdministrator, services.isAdministrator() == false {
            return .disabled(title: title, help: SetupCopy.needsAdminHelp)
        }
        if engine == .mas, !isPresent(.homebrew), !isPresent(.macports) {
            return .disabled(title: title, help: SetupCopy.masNeedsManager)
        }
        if !canRun { return .disabled(title: title, help: services.setupProblem ?? SetupCopy.busyHelp) }
        if !canSetUpEngines { return .disabled(title: title, help: SetupCopy.busyHelp) }
        return .enabled(title: title)
    }

    /// The line a language engine's page shows above its Set Up button: what Set Up installs and through which
    /// manager (or with which rustup), or which manager to set up first. Nil when there's no button (it's there, or it
    /// isn't set up here: the button's own note says why).
    public func setupLine(for engine: EngineID) -> String? {
        guard engine.isLanguage else { return nil }
        switch setupButton(for: engine) {
        case .hidden, .unavailable: return nil
        case .disabled, .enabled: break
        }
        if let rustup = ownRustup(engine) {
            let folder = PathWinner.normalized(rustup.deletingLastPathComponent().path)
            return SetupCopy.toolchainWithRustup(in: InstallAccess.shown(folder, home: NSHomeDirectory()))
        }
        guard let route = EngineSetupPlanner.languageRoute(engine, statuses: engineStatuses) else { return nil }
        if route == .needsManager {
            return SetupCopy.languageNeedsManager(engine, appleSilicon: services.hostInfo.appleSilicon)
        }
        return SetupCopy.languageSetUp(engine, route: route, host: services.hostInfo)
    }

    /// R31: Cargo's rustup without a toolchain (`EngineSetupPlanner.rustupWithoutToolchain`): Set Up only installs the
    /// toolchain with it. Nil for every other engine and state.
    func ownRustup(_ engine: EngineID) -> URL? {
        guard engine == .cargo else { return nil }
        return EngineSetupPlanner.rustupWithoutToolchain(engineStatuses[.cargo], fileExists: services.fileExists)
    }

    /// R30: Set Up of Homebrew's runtime is offered beside a language engine that's there but read-only, as the fix
    /// its page names: Homebrew's Ruby when RubyGems runs macOS's or MacPorts' Ruby, Homebrew's Node when npm's global
    /// folder isn't writable. Only with Homebrew, and only once Installed's last listing of Homebrew worked and showed
    /// no such formula (failing closed while Homebrew couldn't be listed); once it's there, the PATH notes take over.
    /// R31: an npm inside Homebrew's own prefix that isn't Homebrew's (Node's installer in /usr/local on an Intel Mac)
    /// `clashes`: `brew install node` would fail to link over it. Never for Volta's npm (`NpmEngine.voltaReason`).
    func homebrewRuntimeOffer(for engine: EngineID) -> HomebrewRuntimeOffer? {
        guard engine == .gem || engine == .npm, case .present(let path, _)? = engineStatuses[engine],
              case .homebrew(let formula, let prefix)? = EngineSetupPlanner.languageRoute(engine, statuses: engineStatuses),
              !installed.list.failedEngines.contains(.homebrew), let formulae = homebrewFormulae,
              !formulae.contains(formula) else { return nil }
        if engine == .gem { return Self.isAdminOnlyRuby(gem: path.path) ? .offered : nil }
        // Volta's npm is read-only for Volta's own reason: Homebrew's node wouldn't be the npm the shell runs.
        guard let reason = readOnlyReason(for: .npm), reason != NpmEngine.voltaReason else { return nil }
        return path.path.hasPrefix(prefix + "/") ? .clashes(prefix: prefix) : .offered
    }

    /// macOS's own Ruby or MacPorts': RubyGems there is read-only, and Homebrew's Ruby is the fix.
    static func isAdminOnlyRuby(gem: String) -> Bool {
        let source = GemEngine.rubySource(gemPath: gem)
        return source == .system || source == .macports
    }

    /// After each Installed load: Homebrew's formulae, unless Homebrew couldn't be listed (then the last answer stays).
    func homebrewListed(_ refs: Set<PackageRef>) {
        guard !installed.list.failedEngines.contains(.homebrew) else { return }
        homebrewFormulae = Set(refs.filter { $0.engine == .homebrew && $0.kind == .formula }.map(\.name))
    }

    private func isPresent(_ engine: EngineID) -> Bool {
        if case .present? = engineStatuses[engine] { return true }
        return false
    }

    /// "Check again" on an engine's page: off during an engine check and while a run goes, so a check can't be in
    /// flight when a setup run ends (the run's own check would be skipped).
    public var canCheckEngines: Bool { !checkingEngines && !busy }

    /// File > "Set Up Package Manager…".
    public var canShowSetupOffer: Bool { canSetUpEngines && setup.canShowOffer }

    public func showSetupOffer() {
        guard canShowSetupOffer else { return }
        setup.showOffer()
    }
}
