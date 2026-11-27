import Foundation
import BrewxPortCore

/// What the import preview says about an engine that's missing or not working: why, how to set it up, and how many
/// of the file's entries it skips because of it.
public struct EngineSetup: Equatable, Sendable {
    public var engine: EngineID
    /// `PackageCatalog.message(for:status:)`: "Homebrew isn't installed", or the unusable reason.
    public var reason: String
    /// Two short lines.
    public var steps: [String]
    /// The engine's install page.
    public var link: URL
    /// Rows of this engine shown as `engineMissing`. `setup(for:status:)` gives 0; `ImportPreview.make` fills it in.
    public var skippedCount: Int

    public init(engine: EngineID, reason: String, steps: [String], link: URL, skippedCount: Int = 0) {
        self.engine = engine
        self.reason = reason
        self.steps = steps
        self.link = link
        self.skippedCount = skippedCount
    }

    /// Setup help for an engine that's `.missing` or `.unusable`; nil when it's `.present`, and for a language engine
    /// (bundles never carry their tools, so an import never needs one; its Set Up is on its own page).
    public static func setup(for engine: EngineID, status: EngineStatus) -> EngineSetup? {
        guard !engine.isLanguage, let reason = PackageCatalog.message(for: engine, status: status) else { return nil }
        let first: String
        if case .unusable = status {
            first = "Reinstall \(engine == .mas ? "mas" : engine.displayName) from \(site(engine)), or fix the problem shown above."
        } else {
            first = install(engine)
        }
        let again = "Then select \(engine.displayName) in the sidebar and click Check again."
        return EngineSetup(engine: engine, reason: reason, steps: [first, again], link: link(engine))
    }

    /// Install pages: each project's own. nanobrew's site hosts its install script
    /// (`curl https://nanobrew.trilok.ai/install | bash`).
    static func link(_ engine: EngineID) -> URL {
        switch engine {
        case .homebrew: return URL(string: "https://brew.sh")!
        case .macports: return URL(string: "https://www.macports.org/install.php")!
        case .mas: return URL(string: "https://github.com/mas-cli/mas")!
        case .nanobrew: return URL(string: "https://nanobrew.trilok.ai")!
        // Not reached: `setup(for:status:)` gives nil for language engines (their pages' Set Up installs them).
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return URL(string: "https://brew.sh")!
        }
    }

    private static func site(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: return "brew.sh"
        case .macports: return "macports.org"
        case .mas: return "its GitHub page"
        case .nanobrew: return "nanobrew.trilok.ai"
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return "brew.sh"  // not reached, as `link`
        }
    }

    private static func install(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: return "Install Homebrew from brew.sh."
        case .macports: return "Install MacPorts with the installer for your macOS version from macports.org."
        case .mas: return "Install mas by following the steps on its GitHub page."
        case .nanobrew: return "Install nanobrew with the command on nanobrew.trilok.ai."
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return "Install Homebrew from brew.sh."  // not reached
        }
    }
}
