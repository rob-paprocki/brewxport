import Foundation
import BrewxPortCore

/// What the inspector's options fields hold before an install. Turning it into `InstallOptions` is where the
/// rules live: no shell, no quoting, and nothing a root command wouldn't accept.
public struct InstallOptionsDraft: Equatable, Sendable {
    public var version: String
    public var extraArgs: String
    /// true is "+name", false is "-name", absent is the port's default.
    public var variants: [String: Bool]

    public init(version: String = "", extraArgs: String = "", variants: [String: Bool] = [:]) {
        self.version = version
        self.extraArgs = extraArgs
        self.variants = variants
    }

    /// Throws an `EngineError` saying which field is wrong.
    public func options(for engine: EngineID, capabilities: EngineCapabilities) throws -> InstallOptions {
        // Whitespace only: no quoting, no expansion, nothing a shell would read.
        let tokens = extraArgs.split(whereSeparator: \.isWhitespace).map(String.init)
        if engine == .mas, !tokens.isEmpty {
            throw EngineError(engine: engine, message: "\(engine.displayName) takes no extra arguments.")
        }
        for token in tokens {
            guard token.hasPrefix("-") else {
                throw EngineError(engine: engine, message: "Extra arguments must start with a dash: \(token)")
            }
            if engine == .macports, !RootArguments.macPortsExtraArgs.contains(token) {
                let allowed = RootArguments.macPortsExtraArgs.sorted().joined(separator: " ")
                throw EngineError(engine: engine, message: "MacPorts doesn't accept \(token) here. Allowed: \(allowed)")
            }
        }

        let pinned = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty, !capabilities.contains(.versionPinning) {
            throw EngineError(engine: engine, message: "\(engine.displayName) can't install a specific version.")
        }

        let signed = variants.sorted { $0.key < $1.key }.map { ($0.value ? "+" : "-") + $0.key }
        for variant in signed where !RootArguments.isValidVariant(variant) {
            throw EngineError(engine: engine, message: "Not a valid variant name: \(variant.dropFirst())")
        }
        return InstallOptions(version: pinned.isEmpty ? nil : pinned, variants: signed, extraArgs: tokens)
    }
}
