import Foundation
import Observation
import BrewxPortCore

/// What the inspector's Install button shows. Views only bind to it.
public enum InstallAvailability: Equatable, Sendable {
    case ready, running, alreadyInstalled
    /// Installed, and the engine knows a newer version.
    case updateAvailable(installed: String, latest: String)
    /// A nanobrew cask whose details haven't loaded yet.
    case checking
    /// `CaskRouting` said `.needsHomebrew`; the text is the same problem the planner reports.
    case needsHomebrew(String)
}

/// The inspector's package: the row it follows, its details and its install options.
@MainActor @Observable public final class DetailsModel {
    public private(set) var row: PackageRow?
    public private(set) var details: PackageDetails?
    public private(set) var loading = false
    public private(set) var error: String?
    public var options = InstallOptionsDraft() {
        didSet { if options != oldValue { optionsError = nil } }
    }
    /// Why the inspector's Install didn't start: an option the engine won't take. Cleared when the options change
    /// or another package is shown.
    public internal(set) var optionsError: String?

    @ObservationIgnored private let catalog: any PackageQuerying
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(catalog: any PackageQuerying) { self.catalog = catalog }

    /// Cancels the previous load; an answer for an earlier row is dropped. Showing the row that's already
    /// shown keeps its details (a refresh swaps the row's data, not the inspector's page) unless it failed.
    public func show(_ row: PackageRow?) {
        if let row, row.id == self.row?.id, error == nil {
            self.row = row
            return
        }
        task?.cancel()
        generation += 1
        let mine = generation
        self.row = row
        details = nil
        error = nil
        options = InstallOptionsDraft()
        optionsError = nil
        guard let row else {
            loading = false
            task = nil
            return
        }
        loading = true
        let catalog = catalog
        task = Task { [weak self] in
            let result: Result<PackageDetails, Error>
            do { result = .success(try await catalog.info(row.id)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            self.loading = false
            switch result {
            case .success(let found): self.details = found
            case .failure(let failure):
                if let engineError = failure as? EngineError {
                    self.error = EngineErrorText.line(engineError)
                } else {
                    self.error = "\(row.engineName) couldn't load details: \(failure.localizedDescription)"
                }
            }
        }
    }

    public func installAvailability(isRunning: Bool, homebrewPresent: Bool,
                                     isOutdated: Bool = false) -> InstallAvailability {
        if isRunning { return .running }
        guard let row else { return .ready }
        if row.isInstalled {
            if isOutdated, let installed = row.package.installedVersion, let latest = row.package.latestVersion,
               installed != latest {
                return .updateAvailable(installed: installed, latest: latest)
            }
            return .alreadyInstalled
        }
        guard row.id.engine == .nanobrew, row.id.kind == .cask else { return .ready }
        if details == nil, error == nil { return .checking }
        switch CaskRouting.route(needsRoot: details?.installerNeedsRoot, homebrewPresent: homebrewPresent) {
        case .needsHomebrew:
            return .needsHomebrew(CaskRouting.needsHomebrewText(name: row.name))
        case .nanobrew, .homebrew:
            return .ready
        }
    }
}
