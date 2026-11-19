import Foundation

public enum EngineID: String, Codable, Sendable, CaseIterable {
    case homebrew, nanobrew, macports, mas

    /// The name people see in messages.
    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .nanobrew: return "nanobrew"
        case .macports: return "MacPorts"
        case .mas: return "Mac App Store"
        }
    }
}

public enum PackageKind: String, Codable, Sendable {
    case formula, cask, port, app
}

public enum Arch: String, Codable, Sendable {
    case arm64, x86_64

    public static var current: Arch {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// Identifies a package within one engine. For mas, `name` is the numeric app id as a string.
public struct PackageRef: Hashable, Codable, Sendable {
    public let engine: EngineID
    public let kind: PackageKind
    public let name: String

    public init(engine: EngineID, kind: PackageKind, name: String) {
        self.engine = engine
        self.kind = kind
        self.name = name
    }
}

public struct Package: Identifiable, Hashable, Sendable {
    public var id: PackageRef
    public var displayName: String
    public var installedVersion: String?
    public var latestVersion: String?
    public var summary: String?
    /// The architectures the installed copy was built for, where the engine says (MacPorts' `archs`). Two means a
    /// universal build. nil means unknown, or not tied to one (MacPorts' `noarch`).
    public var installedArchs: Set<Arch>?

    public init(
        id: PackageRef,
        displayName: String,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        summary: String? = nil,
        installedArchs: Set<Arch>? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.summary = summary
        self.installedArchs = installedArchs
    }
}

public struct InstallOptions: Codable, Hashable, Sendable {
    public var version: String?
    public var variants: [String]
    public var extraArgs: [String]

    public init(version: String? = nil, variants: [String] = [], extraArgs: [String] = []) {
        self.version = version
        self.variants = variants
        self.extraArgs = extraArgs
    }
}

/// What an engine says about one package, for the details pane and for choosing how to run a cask.
public struct PackageDetails: Sendable, Equatable {
    public var ref: PackageRef
    public var summary: String?
    public var homepage: URL?
    public var installedVersion: String?
    public var latestVersion: String?
    /// nil means the engine doesn't say; an empty array means it says "none".
    public var dependencies: [String]?
    /// MacPorts only. Names without a sign ("universal").
    public var variants: [String]
    /// Casks: true when a pkg or installer artifact is present. nil means unknown.
    public var installerNeedsRoot: Bool?

    public init(
        ref: PackageRef,
        summary: String? = nil,
        homepage: URL? = nil,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        dependencies: [String]? = nil,
        variants: [String] = [],
        installerNeedsRoot: Bool? = nil
    ) {
        self.ref = ref
        self.summary = summary
        self.homepage = homepage
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.dependencies = dependencies
        self.variants = variants
        self.installerNeedsRoot = installerNeedsRoot
    }
}
