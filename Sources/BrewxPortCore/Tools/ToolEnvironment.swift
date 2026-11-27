import Foundation

/// The environment a language tool runs with, and the login-shell variables it may get.
///
/// Besides PATH, BrewxPort takes only the allowlisted location variables below from the user's login shell, so npm,
/// pipx, uv, cargo, gem, bun and mint work on the same folders as in Terminal. Values must be absolute paths (GEM_PATH
/// may be a colon-separated list of them); anything else, and every other variable (tokens, index URLs, proxies), is
/// left out. Each manager's commands get only its own variables plus the shared XDG ones (`variables(for:)`); the
/// values are never logged.
public struct ToolEnvironment: Sendable {
    /// The login-shell variables a language tool may get, exactly these, in this order.
    public static let capturedVariables = [
        "NVM_DIR", "NPM_CONFIG_PREFIX", "npm_config_prefix", "PIPX_HOME", "PIPX_BIN_DIR", "UV_TOOL_DIR",
        "UV_TOOL_BIN_DIR", "CARGO_HOME", "CARGO_INSTALL_ROOT", "RUSTUP_HOME", "GEM_HOME", "GEM_PATH", "BUN_INSTALL",
        "BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN", "MINT_PATH", "MINT_LINK_PATH", "XDG_DATA_HOME", "XDG_BIN_HOME",
        "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
    ]

    /// The only variable whose value is a list of paths.
    static let pathListVariables: Set<String> = ["GEM_PATH"]

    /// The PATH used after the tool's folder when `base` has none.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The longest path macOS accepts (MAXPATHLEN), in bytes.
    static let maxPathBytes = 1024

    /// The XDG folders every language manager may use (uv, pipx and Bun read them).
    static let sharedVariables = ["XDG_DATA_HOME", "XDG_BIN_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]

    /// The captured variables `engine`'s commands get: its own, then the shared XDG ones. None for the system engines,
    /// which never get login-shell variables.
    public static func variables(for engine: EngineID) -> [String] {
        let own: [String]
        switch engine {
        case .npm: own = ["NVM_DIR", "NPM_CONFIG_PREFIX", "npm_config_prefix"]
        case .pipx: own = ["PIPX_HOME", "PIPX_BIN_DIR"]
        case .uv: own = ["UV_TOOL_DIR", "UV_TOOL_BIN_DIR"]
        case .cargo: own = ["CARGO_HOME", "CARGO_INSTALL_ROOT", "RUSTUP_HOME"]
        case .bun: own = ["BUN_INSTALL", "BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN"]
        case .gem: own = ["GEM_HOME", "GEM_PATH"]
        case .mint: own = ["MINT_PATH", "MINT_LINK_PATH"]
        case .homebrew, .nanobrew, .macports, .mas: return []
        }
        return own + sharedVariables
    }

    /// `base`, with the executable's folder first on PATH (so npm finds its own `node` and gem its own `ruby`),
    /// `engine`'s own allowlisted login-shell variables from `captured` (`variables(for:)`) added, and `NO_COLOR=1`.
    /// Cargo also gets `RUSTUP_AUTO_INSTALL=0`, so a rustup proxy never downloads a toolchain behind BrewxPort's back.
    public static func make(for engine: EngineID, executable: URL, captured: [String: String],
                            base: [String: String]) -> [String: String] {
        var environment = base
        let folder = executable.deletingLastPathComponent().path
        let rest = (base["PATH"] ?? fallbackPath).split(separator: ":").map(String.init)
            .filter { !$0.isEmpty && $0 != folder }
        environment["PATH"] = ([folder] + rest).joined(separator: ":")
        let wanted = Set(variables(for: engine))
        environment.merge(allowlisted(captured).filter { wanted.contains($0.key) }) { $1 }
        if engine == .cargo { environment["RUSTUP_AUTO_INSTALL"] = "0" }
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// The entries of `values` that are allowlisted variables with a usable value: an absolute path without a colon
    /// or control characters (a list of them for GEM_PATH, every entry usable). Everything else is dropped.
    public static func allowlisted(_ values: [String: String]) -> [String: String] {
        let names = Set(capturedVariables)
        return values.filter { name, value in
            guard names.contains(name) else { return false }
            guard pathListVariables.contains(name) else { return isAbsolutePath(value) }
            let entries = value.split(separator: ":", omittingEmptySubsequences: false)
            return entries.allSatisfy { isAbsolutePath(String($0)) }
        }
    }

    /// Starts with `/`, holds no colon (which a URL with credentials would) and no control characters, and fits
    /// MAXPATHLEN.
    static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains(":") && value.utf8.count <= maxPathBytes
            && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}
