import Foundation
import BrewxPortCore

/// Small key-value storage behind the preferences, so tests don't touch UserDefaults.
public protocol KeyValueStoring: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class DefaultsStore: KeyValueStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

public final class MemoryStore: KeyValueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    public func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }
}

/// The PATH entries BrewxPort shows and uses to find tools, and the login shell's tool-location variables.
public struct ResolvedPath: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case loginShell, systemDefault }
    public let entries: [String]
    public let source: Source
    /// Why the system PATH was used instead of the login shell's; nil when the login shell answered.
    public let note: String?
    /// The login shell's values of `ToolEnvironment.capturedVariables` that are absolute paths, for the language
    /// tools' commands only; never logged. Empty when the system PATH was used.
    public let environment: [String: String]

    public init(entries: [String], source: Source, note: String? = nil, environment: [String: String] = [:]) {
        self.entries = entries
        self.source = source
        self.note = note
        self.environment = ToolEnvironment.allowlisted(environment)
    }
}

/// Printed, interpolated, debug-printed or dumped, a ResolvedPath shows its source, how many PATH entries it has, the
/// captured variables' names and the note: never a variable's value or a PATH entry (they name the user's folders).
extension ResolvedPath: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let names = environment.keys.sorted()
        var text = "ResolvedPath(source: \(source), PATH entries: \(entries.count), variables: "
            + (names.isEmpty ? "none" : names.joined(separator: " "))
        if let note { text += ", note: \(note)" }
        return text + ")"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["source": source, "pathEntryCount": entries.count,
                                "variableNames": environment.keys.sorted(), "note": note as Any],
               displayStyle: .struct)
    }
}

public protocol PathResolving: Sendable {
    func resolve() async -> ResolvedPath
    /// Drops a cached answer, so the next `resolve()` asks again (after BrewxPort changed a shell startup file).
    func forget() async
    /// `forget()` for a caller that can't wait (the person's Refresh and Check again): the next `resolve()` asks
    /// again, whatever is cached.
    func askAgain()
}

extension PathResolving {
    public func forget() async {}
    public func askAgain() {}
}
