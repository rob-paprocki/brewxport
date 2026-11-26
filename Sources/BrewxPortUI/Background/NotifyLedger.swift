import Foundation
import BrewxPortCore

/// The update versions BrewxPort has already told the person about, so each version of a package notifies once,
/// across relaunches. Kept in `store` under `notifiedUpdates`, as a JSON list of `"engine/kind/name@latestVersion"`.
/// An unreadable value reads as empty.
@MainActor final class NotifyLedger {
    static let key = "notifiedUpdates"

    private let store: any KeyValueStoring
    private var entries: Set<String>

    init(store: any KeyValueStoring) {
        self.store = store
        let saved = store.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        entries = Set(saved ?? [])
    }

    /// The rows whose version hasn't been told yet, in their order.
    func newOnes(in rows: [PackageRow]) -> [PackageRow] {
        rows.filter { !entries.contains(Self.entry($0.package)) }
    }

    /// Notes these rows' versions as told.
    func record(_ rows: [PackageRow]) {
        let before = entries.count
        entries.formUnion(rows.map { Self.entry($0.package) })
        if entries.count != before { save() }
    }

    /// Forgets the versions that aren't in `outdated` any more: the package was updated, or a newer version replaced
    /// that one. Entries for `unanswered` engines stay: their rows are missing because the engine failed this time,
    /// and forgetting them would tell the person again once it answers.
    func prune(outdated: [PackageRow], unanswered: Set<EngineID> = []) {
        let current = Set(outdated.map { Self.entry($0.package) })
        let kept = entries.filter { entry in
            current.contains(entry) || EngineID(rawValue: String(entry.prefix { $0 != "/" })).map(unanswered.contains) == true
        }
        guard kept != entries else { return }
        entries = kept
        save()
    }

    static func entry(_ package: Package) -> String {
        let ref = package.id
        return "\(ref.engine.rawValue)/\(ref.kind.rawValue)/\(ref.name)@\(package.latestVersion ?? "")"
    }

    private func save() {
        store.set(try? JSONEncoder().encode(entries.sorted()), forKey: Self.key)
    }
}
