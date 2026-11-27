import BrewxPortCore

/// What an engine's sidebar row shows.
public enum EngineRowText {
    /// The version, or what's wrong. A nil status means detection hasn't answered yet.
    public static func subtitle(_ status: EngineStatus?) -> String {
        switch status {
        case .present(_, let version)?: version
        case .missing?: "Not installed"
        case .unusable?: "Not working"
        case .unsupported?: "Too old"
        case nil: "Checking…"
        }
    }

    /// The row's tooltip: why an engine is too old, then what its last check couldn't look up ("2 tools couldn't be
    /// checked: black, ruff"); nil when there's neither.
    public static func help(_ status: EngineStatus?, unchecked: String?) -> String? {
        var lines: [String] = []
        if case .unsupported(_, _, let reason)? = status { lines.append(reason) }
        if let unchecked { lines.append("Last check: " + unchecked) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    public static func symbol(_ id: EngineID) -> String {
        switch id {
        case .homebrew: "mug.fill"
        case .nanobrew: "hare.fill"
        case .macports: "shippingbox.fill"
        case .mas: "bag.fill"
        case .npm: "cube.fill"
        case .pipx: "terminal.fill"
        case .uv: "bolt.fill"
        case .cargo: "hammer.fill"
        case .bun: "flame.fill"
        case .gem: "diamond.fill"
        case .mint: "leaf.fill"
        }
    }

    /// The engine page's Capabilities lines. Every language engine has the same one, what BrewxPort does with each of
    /// them: how a manager prints its lists (npm's and pipx's JSON) is BrewxPort's business, not the person's. A system
    /// engine's are its capabilities in a fixed order, or the plain line when it has none.
    public static func capabilityLines(for engine: EngineID, _ capabilities: EngineCapabilities) -> [String] {
        guard !engine.isLanguage else { return ["Install, update and remove command-line tools"] }
        let names = Self.capabilities(capabilities)
        return names.isEmpty ? ["Install, update and remove"] : names
    }

    /// The engine page's capability list, in a fixed order.
    public static func capabilities(_ capabilities: EngineCapabilities) -> [String] {
        var names: [String] = []
        if capabilities.contains(.casks) { names.append("Casks (Mac apps)") }
        if capabilities.contains(.versionPinning) { names.append("Install a specific version") }
        if capabilities.contains(.sourceBuilds) { names.append("Builds from source, with variants") }
        if capabilities.contains(.jsonOutput) { names.append("Machine-readable output") }
        return names
    }

    public static func statusSymbol(_ status: EngineStatus?) -> String {
        switch status {
        case .present?: "checkmark.circle.fill"
        case .missing?: "minus.circle"
        case .unusable?: "exclamationmark.triangle.fill"
        case .unsupported?: "arrow.up.circle"
        case nil: "ellipsis.circle"
        }
    }
}
