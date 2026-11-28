import Foundation

/// Raw values are stored (ignored and skipped packages, the notify ledger, bundles), so they never change. The system
/// package managers come first, then the language package managers, each group in the order its sidebar shows it.
public enum EngineID: String, Codable, Sendable, CaseIterable {
    case homebrew, nanobrew, macports, mas
    case npm, pipx, uv, cargo, bun, gem, mint

    /// The name people see in messages.
    public var displayName: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .nanobrew: return "nanobrew"
        case .macports: return "MacPorts"
        case .mas: return "Mac App Store"
        case .npm: return "npm"
        case .pipx: return "pipx"
        case .uv: return "uv"
        case .cargo: return "Cargo"
        case .bun: return "Bun"
        case .gem: return "RubyGems"
        case .mint: return "Mint"
        }
    }

    public var group: EngineGroup {
        switch self {
        case .homebrew, .nanobrew, .macports, .mas: return .system
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return .languages
        }
    }

    /// A language package manager: installs a language's global command-line tools, always as the user.
    public var isLanguage: Bool { group == .languages }

    /// The display name's possessive: "Cargo's", but "RubyGems'" and "MacPorts'": a package manager's name that ends in
    /// "s" takes the apostrophe alone. Only for managers' names: a package's name always takes "'s" ("less's").
    public var possessive: String { displayName.hasSuffix("s") ? displayName + "'" : displayName + "'s" }
}

/// Which sidebar group an engine is listed in.
public enum EngineGroup: String, Sendable, CaseIterable {
    /// Homebrew, nanobrew, MacPorts and the Mac App Store.
    case system
    /// npm, pipx, uv, Cargo, Bun, RubyGems and Mint.
    case languages

    /// The sidebar section's title.
    public var title: String {
        switch self {
        case .system: return "Engines"
        case .languages: return "Languages"
        }
    }
}

public enum PackageKind: String, Codable, Sendable {
    /// `tap` is Homebrew only: a third-party formula repository (`user/repo`), added with `brew tap`.
    /// `tool` is the language engines' only kind: a global command-line tool (an npm package, a crate, a gem).
    case formula, cask, port, app, tap, tool
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
    /// MacPorts only: the variants the port was installed with, signs kept (`requested_variants='+universal'` gives
    /// `["+universal"]`). `installedVersion` stays as port reports it.
    public var requestedVariants: [String]
    /// Homebrew only: the tap-qualified name (`felixkratz/formulae/borders`), set only for a package from a tap
    /// other than `homebrew/core` or `homebrew/cask`. `id.name` stays the bare name; an export writes this.
    public var fullName: String?
    /// Whether the user asked for this package, as opposed to it coming in as another one's dependency. nil when the
    /// engine doesn't say (nanobrew, an older Homebrew install record, a failed MacPorts `requested` query). Only
    /// installed lists set it; an export that leaves dependencies out keeps every package where it's nil.
    public var installedOnRequest: Bool?

    public init(
        id: PackageRef,
        displayName: String,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        summary: String? = nil,
        installedArchs: Set<Arch>? = nil,
        requestedVariants: [String] = [],
        fullName: String? = nil,
        installedOnRequest: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.summary = summary
        self.installedArchs = installedArchs
        self.requestedVariants = requestedVariants
        self.fullName = fullName
        self.installedOnRequest = installedOnRequest
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
    /// The name the engine itself gave the package it answered with, which can differ from `ref.name`: Homebrew
    /// answers an alias (`python3`) with the formula it stands for (`python@3.15`), and MacPorts gives a port's own
    /// capitals (`ImageMagick` for `imagemagick`). nil means the answer didn't say.
    public var reportedName: String?
    /// The commands the package puts on disk, where the engine says: a crate's binaries (ripgrep's `rg`), whose names
    /// often differ from the package's. nil means the engine doesn't say; an empty array means it has none.
    public var executables: [String]?

    public init(
        ref: PackageRef,
        summary: String? = nil,
        homepage: URL? = nil,
        installedVersion: String? = nil,
        latestVersion: String? = nil,
        dependencies: [String]? = nil,
        variants: [String] = [],
        installerNeedsRoot: Bool? = nil,
        reportedName: String? = nil,
        executables: [String]? = nil
    ) {
        self.reportedName = reportedName
        self.executables = executables
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
