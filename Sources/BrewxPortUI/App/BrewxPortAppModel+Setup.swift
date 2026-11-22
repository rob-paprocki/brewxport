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

extension BrewxPortAppModel {
    /// The button for a missing engine's Engines page and its Bundles banner.
    public func setupButton(for engine: EngineID) -> SetupButtonState {
        guard engineStatuses[engine] == .missing else { return .hidden }
        guard EngineSetupPlanner.offered(host: services.hostInfo).contains(engine) else {
            return engine == .homebrew ? .unavailable(note: SetupCopy.intelHomebrew) : .hidden
        }
        let title = SetupCopy.buttonTitle(engine)
        if services.isDemo { return .disabled(title: title, help: SetupCopy.demoHelp) }
        if services.isAdministrator() == false { return .disabled(title: title, help: SetupCopy.needsAdminHelp) }
        if engine == .mas, !isPresent(.homebrew), !isPresent(.macports) {
            return .disabled(title: title, help: SetupCopy.masNeedsManager)
        }
        if !canRun { return .disabled(title: title, help: services.setupProblem ?? SetupCopy.busyHelp) }
        if !canSetUpEngines { return .disabled(title: title, help: SetupCopy.busyHelp) }
        return .enabled(title: title)
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
