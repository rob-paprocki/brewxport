import BrewxPortCore
import BrewxPortRun

/// The words on the setup screen and its buttons. Kept out of the views so they can be tested and checked in one place.
public enum SetupCopy {
    public static let intelHomebrew = "Homebrew doesn't support Intel Macs. MacPorts does the same job."
    public static let demoHelp = "Not available in demo mode"
    public static let busyHelp = "Wait for the current task to finish."
    public static let needsAdminHelp = "Needs an administrator account."
    public static let masNeedsManager = "Set up Homebrew or MacPorts first: mas installs through one of them."

    public static let offerTitle = "Set up a package manager"
    public static let offerSubtitle = "BrewxPort needs one to install anything. Pick one to set up now."
    public static let recommendedLabel = "Recommended"
    public static let adminNote = "Needs an administrator password."

    public static let approvalTitle = "Approve BrewxPort's helper"
    public static let approvalText = """
        Setting up a package manager needs BrewxPort's helper. Open Login Items, switch BrewxPort on under \
        "Allow in the Background", and setup carries on by itself.
        """

    public static let failedTitle = "Setup didn't finish"
    public static let cannotTitle = "Setup couldn't start"

    /// One line on what it is.
    public static func blurb(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: "Installs command-line tools and Mac apps. The usual first choice."
        case .macports: "An older package manager for command-line tools and libraries. Runs on every Mac."
        case .nanobrew: "A small, fast package manager that installs Homebrew's packages."
        case .mas: "Installs and updates Mac App Store apps from the command line."
        case .npm: "Installs JavaScript command-line tools from the npm registry."
        case .pipx: "Installs Python command-line tools, each in its own environment."
        case .uv: "Installs Python command-line tools, each in its own environment, with uv."
        case .cargo: "Builds and installs Rust command-line tools from crates.io."
        case .bun: "Installs JavaScript command-line tools with Bun."
        case .gem: "Installs Ruby command-line tools (gems)."
        case .mint: "Installs Swift command-line tools from their GitHub repositories."
        }
    }

    /// Download size and password note, as the real downloads measured in the installer spike. nanobrew's size wasn't
    /// measured, so it only says small. mas and the language engines go in through whichever package manager is
    /// there: a Homebrew formula installs as the user, MacPorts goes through the helper.
    public static func detail(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: "About 160 MB. \(adminNote)"
        case .macports: "About 8 MB, plus Apple's Command Line Tools (about 1.3 GB) if you don't have them. \(adminNote)"
        case .nanobrew: "A small download. \(adminNote)"
        case .mas: "Installed through Homebrew or MacPorts. Through MacPorts it asks for an administrator password."
        case .pipx, .uv, .cargo, .mint:
            "Installed through Homebrew, or MacPorts on a Mac without it. Through MacPorts it asks for an administrator "
                + "password."
        case .npm, .bun, .gem: "Installed through Homebrew."
        }
    }

    /// A language engine's page, when Set Up can install it here: what it installs and through which manager. Cargo
    /// adds the toolchain. Homebrew in /usr/local (an Intel Mac's) has no ready-built copy of some (`intelBuild`), and
    /// says so.
    public static func languageSetUp(_ engine: EngineID, route: LanguageSetupRoute, host: HostInfo) -> String? {
        let then: String
        switch engine {
        case .npm: then = ", which includes npm"
        case .gem: then = ", which includes RubyGems"
        case .cargo: then = ", then Rust's stable toolchain"
        default: then = ""
        }
        switch route {
        case .homebrew(let formula, let prefix):
            let slow = prefix == "/usr/local" ? intelBuild(engine, macOSMajor: host.macOSMajor).map { " " + $0 } : nil
            return "Set Up installs Homebrew's \(formula)\(then).\(slow ?? "")"
        case .macports(let port):
            return "Set Up installs MacPorts' \(port)\(then). \(adminNote)"
        case .needsManager, .homebrewOnly:
            return nil
        }
    }

    /// What Intel Homebrew builds from source instead of pouring a bottle, per the research: rustup (no x86_64 bottles,
    /// so Rust first), bun (bottles for arm64 only) and mint (Intel bottles only for Sonoma and Ventura, so from
    /// macOS 15 on). Nil where a bottle exists.
    static func intelBuild(_ engine: EngineID, macOSMajor: Int) -> String? {
        switch engine {
        case .cargo: "On an Intel Mac, Homebrew builds Rust from source first, which can take a while."
        case .bun: "On an Intel Mac, Homebrew builds Bun from source, which can take a while."
        case .mint where macOSMajor >= 15: "On an Intel Mac, Homebrew builds Mint from source, which can take a while."
        default: nil
        }
    }

    /// R30: the button beside a read-only RubyGems (macOS's or MacPorts' Ruby) or npm (a global folder this account
    /// can't change) when Homebrew is there without that runtime.
    public static func homebrewRuntimeButton(_ engine: EngineID) -> String {
        engine == .npm ? "Set Up Homebrew's Node…" : "Set Up Homebrew's Ruby…"
    }

    /// R31: Cargo's line when its own rustup has no toolchain; `folder` as the page shows it (`~/.cargo/bin`).
    public static func toolchainWithRustup(in folder: String) -> String {
        "Set Up installs Rust's stable toolchain with the rustup in \(folder)."
    }

    /// R31: npm's line when it lives in Homebrew's prefix without being Homebrew's (Node's installer in /usr/local on an
    /// Intel Mac): `brew install node` couldn't link over it.
    public static func homebrewNodeClash(prefix: String) -> String {
        "Homebrew's node would clash with the node already in \(prefix), so BrewxPort doesn't offer it."
    }

    /// Cargo's Set Up couldn't start once the login shell had answered: something modal came up meanwhile.
    public static func setupInterrupted(_ engine: EngineID) -> String {
        "\(engine.displayName) wasn't set up: something else came up while BrewxPort read your shell's settings. Try "
            + "Set Up again."
    }

    /// Why npm, Bun and RubyGems aren't set up without Homebrew (MacPorts' Node and Ruby keep their global tools where
    /// only an administrator can write; it builds Bun from source for hours), and what to do instead: Homebrew where it
    /// runs, or a copy in the home folder.
    public static func homebrewOnly(_ engine: EngineID, appleSilicon: Bool) -> String {
        let why: String, runtime: String, userLevel: String
        switch engine {
        case .npm:
            why = "MacPorts' Node keeps its global tools in /opt/local, which only an administrator can change."
            runtime = "Node"
            userLevel = "with a version manager such as nvm"
        case .gem:
            why = "MacPorts' Ruby keeps its gems in /opt/local, which only an administrator can change."
            runtime = "Ruby"
            userLevel = "with a version manager such as rbenv"
        default:
            why = "MacPorts builds Bun from source, which takes hours."
            runtime = "Bun"
            userLevel = "as bun.com describes"
        }
        let instead = appleSilicon
            ? "Set up Homebrew, or install \(runtime) in your home folder \(userLevel)."
            : "Install \(runtime) in your home folder instead, \(userLevel)."
        return "BrewxPort sets up \(engine.displayName) only through Homebrew: \(why) \(instead)"
    }

    /// pipx, uv, Cargo or Mint with neither Homebrew nor MacPorts: which to set up first. An Intel Mac can't have
    /// Homebrew set up.
    public static func languageNeedsManager(_ engine: EngineID, appleSilicon: Bool) -> String {
        appleSilicon
            ? "Set Up installs \(engine.displayName) through Homebrew or MacPorts. Set up one of them first."
            : "Set Up installs \(engine.displayName) through MacPorts. Set up MacPorts first."
    }

    public static func buttonTitle(_ engine: EngineID) -> String { "Set Up \(engine.displayName)…" }
    public static func readyTitle(_ engine: EngineID) -> String { "\(engine.displayName) is ready" }
    public static let readyText = "Its packages will show up in BrewxPort now."
}
