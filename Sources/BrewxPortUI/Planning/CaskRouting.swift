import Foundation

/// Where a nanobrew cask install goes (spec R11). nanobrew never runs a cask's installer with administrator
/// rights, so a cask whose installer needs them is installed with Homebrew instead, when Homebrew is there.
public enum CaskRoute: Sendable, Equatable { case nanobrew, homebrew, needsHomebrew }

public enum CaskRouting {
    /// The one wording for "this cask can't be installed without Homebrew", used by the planner and the inspector.
    public static func needsHomebrewText(name: String) -> String {
        "\(name) needs Homebrew: its installer needs administrator rights, which nanobrew can't use."
    }

    /// nb cask installs only (upgrade/remove stay on nb: brew doesn't own a cask nb installed).
    ///
    /// `needsRoot` is `PackageDetails.installerNeedsRoot`. An unknown answer (nil) counts as "needs root".
    public static func route(needsRoot: Bool?, homebrewPresent: Bool) -> CaskRoute {
        if needsRoot == false { return .nanobrew }
        return homebrewPresent ? .homebrew : .needsHomebrew
    }
}
