import BrewxPortCore

/// What an engine's sidebar row shows.
public enum EngineRowText {
    /// The version, or what's wrong. A nil status means detection hasn't answered yet.
    public static func subtitle(_ status: EngineStatus?) -> String {
        switch status {
        case .present(_, let version)?: version
        case .missing?: "Not installed"
        case .unusable?: "Not working"
        case nil: "Checking…"
        }
    }

    public static func symbol(_ id: EngineID) -> String {
        switch id {
        case .homebrew: "mug.fill"
        case .nanobrew: "hare.fill"
        case .macports: "shippingbox.fill"
        case .mas: "bag.fill"
        }
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
        case nil: "ellipsis.circle"
        }
    }
}
