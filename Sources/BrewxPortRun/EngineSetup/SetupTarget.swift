import BrewxPortCore
import Foundation

/// Something the app can set up from scratch.
public enum SetupTarget: String, Codable, Sendable, CaseIterable {
    case homebrew, macports, nanobrew, commandLineTools

    /// The GitHub repository whose latest release carries the installer. Nil for the Command Line Tools.
    public var repo: String? {
        switch self {
        case .homebrew: return "Homebrew/brew"
        case .macports: return "macports/macports-base"
        case .nanobrew: return "justrach/nanobrew"
        case .commandLineTools: return nil
        }
    }

    public var engine: EngineID? {
        switch self {
        case .homebrew: return .homebrew
        case .macports: return .macports
        case .nanobrew: return .nanobrew
        case .commandLineTools: return nil
        }
    }
}

/// The facts about this Mac that decide which installer fits.
public struct HostInfo: Sendable, Equatable {
    public var appleSilicon: Bool
    public var macOSMajor: Int

    public init(appleSilicon: Bool, macOSMajor: Int) {
        self.appleSilicon = appleSilicon
        self.macOSMajor = macOSMajor
    }

    public static func current() -> HostInfo {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return HostInfo(appleSilicon: ok && value == 1,
                        macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

public enum SetupError: Error, Equatable, Sendable {
    case unsupportedHost(String)
    case noAsset(String)
    case network(String)
    case verification(String)
    case alreadyInstalled(String)
    case installFailed(String)

    /// The sentence the run log shows.
    public var message: String {
        switch self {
        case .unsupportedHost(let text), .noAsset(let text), .network(let text),
             .verification(let text), .alreadyInstalled(let text), .installFailed(let text):
            return text
        }
    }
}
