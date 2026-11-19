import Foundation

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

/// The PATH entries BrewxPort shows and uses to find tools.
public struct ResolvedPath: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case loginShell, systemDefault }
    public let entries: [String]
    public let source: Source
    /// Why the system PATH was used instead of the login shell's; nil when the login shell answered.
    public let note: String?

    public init(entries: [String], source: Source, note: String? = nil) {
        self.entries = entries
        self.source = source
        self.note = note
    }
}

public protocol PathResolving: Sendable { func resolve() async -> ResolvedPath }
