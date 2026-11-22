import Foundation
import BrewxPortCore

/// One line in a package table. The text fields are the sort keys, so every column sorts by what it shows.
public struct PackageRow: Identifiable, Hashable, Sendable {
    public let package: Package
    /// The arch the row's engine runs as.
    public let arch: Arch
    /// What the installed copy was built for: the package's own `installedArchs`, or one borrowed from the
    /// Installed row for the same ref (Updates rows). nil means unknown.
    public let installedArchs: Set<Arch>?
    public var isInstalled: Bool

    public var id: PackageRef { package.id }
    public var name: String { package.displayName }
    public var engineName: String { package.id.engine.displayName }
    public var kindName: String { package.id.kind.rawValue }
    public var installed: String { package.installedVersion ?? "—" }
    public var latest: String { package.latestVersion ?? "—" }
    /// The tooltip on a dash in the version column. `brew search` returns names only; the inspector has the version.
    public var latestHelp: String? { package.latestVersion == nil ? "Version shown in details" : nil }
    /// The Arch column: the installed copy's arch where the engine reports it ("universal" for more than one),
    /// otherwise the arch the engine runs as.
    public var archName: String {
        guard let archs = installedArchs, let first = archs.first else { return arch.rawValue }
        return archs.count > 1 ? "universal" : first.rawValue
    }

    public init(package: Package, arch: Arch, installedArchs: Set<Arch>? = nil, isInstalled: Bool? = nil) {
        self.package = package
        self.arch = arch
        self.installedArchs = package.installedArchs ?? installedArchs
        self.isInstalled = isInstalled ?? (package.installedVersion != nil)
    }
}

/// Which table a menu or action belongs to.
public enum PackageView: Sendable { case discover, updates, installed, bundles }
