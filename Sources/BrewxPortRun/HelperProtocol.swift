import Foundation
import Security

/// The helper's launchd Mach service (the `MachServices` key of its LaunchDaemon plist).
public let brewxPortHelperMachService = "com.brewxport.helper"

/// Bump when the protocol or the allow-list changes, so the app re-registers an old helper.
public let brewxPortHelperVersion = 1

/// Info.plist key (embedded in the helper with `-sectcreate __TEXT __info_plist`) holding the code-signing
/// requirement every client must satisfy. Missing, blank or unparsable means the helper refuses every connection.
public let brewxPortClientRequirementKey = "BrewxPortClientRequirement"

/// The app's side of the helper connection. Every `reply` is called exactly once.
@objc public protocol BrewxPortHelperProtocol {
    func version(reply: @escaping @Sendable (Int) -> Void)
    /// `authorization` is `AuthorizationMakeExternalForm` output (exactly `kAuthorizationExternalFormLength` bytes)
    /// for an authorization that holds `brewxPortRunRight`. Replies `(exitCode, nil)` once `port` has run, or
    /// `(-1, errorText)` if it was refused or couldn't run.
    func runPort(authorization: Data, arguments: [String], reply: @escaping @Sendable (Int32, String?) -> Void)
}

/// Exported by the app on the same connection; receives `port`'s output one line at a time.
@objc public protocol BrewxPortHelperClientProtocol {
    func output(line: String, isError: Bool)
}

/// The two interfaces, built in one place so the app and the helper agree on them.
public enum HelperInterfaces {
    /// Pins the classes NSXPC may decode for `runPort`'s `arguments`, so a hostile peer can't smuggle a
    /// non-string into the array (which would trap when it bridges to `[String]`).
    public static func helper() -> NSXPCInterface {
        let interface = NSXPCInterface(with: BrewxPortHelperProtocol.self)
        let classes = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        interface.setClasses(classes,
                             for: #selector(BrewxPortHelperProtocol.runPort(authorization:arguments:reply:)),
                             argumentIndex: 1, ofReply: false)
        return interface
    }

    public static func client() -> NSXPCInterface {
        NSXPCInterface(with: BrewxPortHelperClientProtocol.self)
    }
}

public enum HelperClientRequirement {
    /// The trimmed `BrewxPortClientRequirement` string from the helper's Info.plist, or nil when it's missing, blank
    /// or doesn't parse as a code-signing requirement. Nil means the helper accepts no connection at all.
    public static func read(from infoDictionary: [String: Any]?) -> String? {
        guard let raw = infoDictionary?[brewxPortClientRequirementKey] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              requirement != nil else { return nil }
        return text
    }
}

public enum HelperCompatibility {
    /// True when the installed helper speaks the bundled app's protocol.
    public static func check(installed: Int, bundled: Int) -> Bool {
        installed == bundled
    }
}

public enum HelperError: Error, Equatable, Sendable {
    /// A token (or argv shape) outside the allow-list. The associated value is the offending token.
    case notAllowed(String)
    /// The authorization didn't hold `brewxPortRunRight`, or the helper couldn't define the right.
    case notAuthorized
    /// `port` or one of the directories above it isn't safely root-owned. The value says what's wrong.
    case badExecutable(String)

    /// Text for the reply's error string.
    public var message: String {
        switch self {
        case .notAllowed(let token): "Not allowed in a root command: \(token)"
        case .notAuthorized: "Not authorized. Enter your administrator password again."
        case .badExecutable(let detail): "MacPorts' port command isn't safe to run as root: \(detail)"
        }
    }
}
