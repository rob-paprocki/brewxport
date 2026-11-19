import Foundation
import BrewxPortCore

/// Which updates the user ignores for good, and which single versions they skipped.
@MainActor public final class UpdatePreferences {
    static let ignoredKey = "ignoredPackages"
    static let skippedKey = "skippedVersions"

    private struct Skip: Codable, Equatable {
        var ref: PackageRef
        var version: String
    }

    private let store: any KeyValueStoring
    private var ignored: Set<PackageRef>
    private var skipped: [PackageRef: String]

    /// Decodes one list entry, or nil when that entry doesn't decode, so one bad entry (an engine or kind a later
    /// version renamed, say) drops only itself and not every ignore or skip.
    private struct Entry<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
    }

    /// The entries of a stored JSON list that decode; empty when the list itself doesn't.
    private static func entries<T: Decodable>(_ type: T.Type, _ data: Data?) -> [T] {
        guard let data, let list = try? JSONDecoder().decode([Entry<T>].self, from: data) else { return [] }
        return list.compactMap(\.value)
    }

    public init(store: any KeyValueStoring) {
        self.store = store
        ignored = Set(Self.entries(PackageRef.self, store.data(forKey: Self.ignoredKey)))
        let skips = Self.entries(Skip.self, store.data(forKey: Self.skippedKey))
        skipped = Dictionary(skips.map { ($0.ref, $0.version) }, uniquingKeysWith: { _, last in last })
    }

    public func isIgnored(_ ref: PackageRef) -> Bool { ignored.contains(ref) }

    public func ignore(_ refs: some Sequence<PackageRef>) {
        ignored.formUnion(refs)
        saveIgnored()
    }

    public func unignore(_ refs: some Sequence<PackageRef>) {
        ignored.subtract(refs)
        saveIgnored()
    }

    /// True when the user skipped exactly the version this package would update to.
    public func isSkipped(_ package: Package) -> Bool {
        guard let version = skipped[package.id], let latest = package.latestVersion else { return false }
        return version == latest
    }

    public func skip(_ ref: PackageRef, version: String) {
        skipped[ref] = version
        saveSkipped()
    }

    /// Drops skips whose package now has a different latest version. A package missing from `outdated` keeps its
    /// skip, so one failed engine query doesn't forget it.
    public func prune(outdated: [Package]) {
        var changed = false
        for package in outdated {
            if let version = skipped[package.id], version != package.latestVersion {
                skipped[package.id] = nil
                changed = true
            }
        }
        if changed { saveSkipped() }
    }

    private static func order(_ a: PackageRef, _ b: PackageRef) -> Bool {
        (a.engine.rawValue, a.kind.rawValue, a.name) < (b.engine.rawValue, b.kind.rawValue, b.name)
    }

    private func saveIgnored() {
        let list = ignored.sorted(by: Self.order)
        store.set(try? JSONEncoder().encode(list), forKey: Self.ignoredKey)
    }

    private func saveSkipped() {
        let list = skipped.map { Skip(ref: $0.key, version: $0.value) }.sorted { Self.order($0.ref, $1.ref) }
        store.set(try? JSONEncoder().encode(list), forKey: Self.skippedKey)
    }
}
