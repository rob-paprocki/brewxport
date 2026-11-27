import Foundation
import BrewxPortCore

/// The update versions BrewxPort has already told the person about, so each version of a package notifies once,
/// across relaunches. Kept in `store` under `notifiedUpdates`, as a JSON list of `"engine/kind/name@latestVersion"`.
/// A notice of another kind keeps its own entries, under a namespace (`"runtime:homebrew/formula/ruby@4.1.0"`), so a
/// version told as available is still told once as a held runtime. An unreadable value reads as empty.
@MainActor final class NotifyLedger {
    static let key = "notifiedUpdates"

    private let store: any KeyValueStoring
    private var entries: Set<String>

    init(store: any KeyValueStoring) {
        self.store = store
        let saved = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        entries = Set(saved ?? [])
    }

    /// The kinds of notice with entries of their own.
    enum Namespace: String, CaseIterable {
        /// "Ruby 4.1 is ready": a Homebrew runtime held back for language tools.
        case runtime
    }

    /// The rows whose version hasn't been told yet (in `namespace`'s notices, when given), in their order.
    func newOnes(in rows: [PackageRow], namespace: Namespace? = nil) -> [PackageRow] {
        rows.filter { !entries.contains(Self.entry($0.package, namespace: namespace)) }
    }

    /// Notes these rows' versions as told (in `namespace`'s notices, when given).
    func record(_ rows: [PackageRow], namespace: Namespace? = nil) {
        let before = entries.count
        entries.formUnion(rows.map { Self.entry($0.package, namespace: namespace) })
        if entries.count != before { save() }
    }

    /// Forgets the versions that aren't in `outdated` any more: the package was updated, or a newer version replaced
    /// that one. Entries for `unanswered` engines stay: their rows are missing because the engine failed this time,
    /// and forgetting them would tell the person again once it answers. So do those a partial check couldn't look up
    /// (R6, `unchecked`): the named packages, and every entry of an engine whose check couldn't name what it missed
    /// or only said why (its note).
    func prune(outdated: [PackageRow], unanswered: Set<EngineID> = [],
               unchecked: [EngineID: UncheckedPackages] = [:]) {
        let current = Set(outdated.flatMap { row in
            [Self.entry(row.package)] + Namespace.allCases.map { Self.entry(row.package, namespace: $0) }
        })
        let kept = entries.filter { entry in
            let plain = Namespace.allCases.lazy.map { $0.rawValue + ":" }.first(where: entry.hasPrefix)
                .map { String(entry.dropFirst($0.count)) } ?? entry
            guard !current.contains(entry) else { return true }
            guard let engine = EngineID(rawValue: String(plain.prefix { $0 != "/" })) else { return false }
            if unanswered.contains(engine) { return true }
            guard let missed = unchecked[engine], !missed.isEmpty else { return false }
            if missed.unnamed || missed.note != nil { return true }
            return Self.name(plain).map { missed.reasons[$0] != nil } ?? false
        }
        guard kept != entries else { return }
        entries = kept
        save()
    }

    /// The package name in a plain entry (`engine/kind/name@version`): everything after the second slash, up to the
    /// last `@`, so npm's `@scope/name` and Mint's `owner/repo` come back whole. Nil for an entry not in that shape.
    static func name(_ plain: String) -> String? {
        let parts = plain.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let at = parts[2].lastIndex(of: "@") else { return nil }
        let name = parts[2][..<at]
        return name.isEmpty ? nil : String(name)
    }

    static func entry(_ package: Package, namespace: Namespace? = nil) -> String {
        let ref = package.id
        let plain = "\(ref.engine.rawValue)/\(ref.kind.rawValue)/\(ref.name)@\(package.latestVersion ?? "")"
        return namespace.map { $0.rawValue + ":" + plain } ?? plain
    }

    private func save() {
        store.set(try? JSONEncoder().encode(entries.sorted()), forKey: Self.key)
    }
}
