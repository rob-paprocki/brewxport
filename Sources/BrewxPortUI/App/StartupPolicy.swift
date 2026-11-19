import CoreFoundation
import Foundation

/// What the app shows at launch.
public enum Startup: Equatable { case live, developmentMacNotice, demo }

/// Keeps a normal launch on a development Mac away from its engines and its helper.
public enum StartupPolicy {
    /// A boolean in the `com.brewxport.app` domain: `defaults write com.brewxport.app BrewxPortDevelopmentMac -bool true`.
    public static let developmentMacKey = "BrewxPortDevelopmentMac"
    static let domain = "com.brewxport.app"

    /// The window a normal launch shows on a development Mac. In that case it's the whole app.
    public static let developmentMacNotice =
        "This Mac is marked as a development Mac, so BrewxPort won't touch its engines or its helper here. "
        + "Launch it with --demo."

    /// Read with `CFPreferencesCopyAppValue` in the `com.brewxport.app` domain, so the answer is the same for the
    /// bundled app and for `swift run`, whose own bundle identifier differs.
    public static func isDevelopmentMac() -> Bool {
        isDevelopmentMac(domain: domain)
    }

    static func isDevelopmentMac(domain: String) -> Bool {
        developmentMacFlag(from: CFPreferencesCopyAppValue(developmentMacKey as CFString, domain as CFString))
    }

    /// The marker's value as a flag: a boolean or number (non-zero is true), or the text "1", "true" or "yes" in
    /// any case. Anything else, or no value, is false.
    static func developmentMacFlag(from value: CFPropertyList?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return ["1", "true", "yes"].contains(text.lowercased()) }
        return false
    }

    /// `.selfCheck` gets `.live`, but `main` runs the self-check before it would ask.
    public static func decide(mode: LaunchMode, developmentMac: Bool) -> Startup {
        switch mode {
        case .selfCheck: .live
        case .demo: .demo
        case .normal: developmentMac ? .developmentMacNotice : .live
        }
    }
}
