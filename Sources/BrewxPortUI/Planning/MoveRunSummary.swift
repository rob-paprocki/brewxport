import Foundation
import BrewxPortCore

/// The one line a finished move adds to the run log when an old copy wasn't removed, saying which and why. Nil when
/// every removal worked, when the move had no removals, or when nothing ran (the log already says why).
public enum MoveRunSummary {
    /// `rows` are the run's step rows after it ended. `missing` are the names the check found missing on the
    /// target, nil when it never answered.
    public static func note(for run: MoveRun, rows: [RunStepRow], missing: [String]?,
                            source: EngineID, target: EngineID) -> String? {
        guard rows.contains(where: { $0.state != .skipped && $0.state != .waiting }) else { return nil }
        let removals = rows.filter { $0.operation == .remove && run.removalNames[$0.title] != nil }
        let kept = removals.filter { $0.state != .succeeded }
        guard !kept.isEmpty else { return nil }
        let keptNames = kept.compactMap { run.removalNames[$0.title] }
        let copies = keptNames.count == 1
            ? "The \(source.displayName) copy of \(keptNames[0]) is still installed"
            : "The \(source.displayName) copies of \(list(keptNames)) are still installed"

        if let failed = removals.first(where: { if case .failed = $0.state { true } else { false } }),
           let name = run.removalNames[failed.title] {
            return "\(copies) because removing \(name) failed."
        }
        if removals.contains(where: { $0.state == .succeeded || $0.state == .stopped }) {
            return "\(copies) because the move was cancelled."
        }

        // Nothing was removed: say what stopped the removals.
        let check = rows.first { $0.title == run.checkTitle && $0.operation != .remove }
        if case .failed = check?.state {
            let names = missing ?? []
            if names.isEmpty { return "Nothing was removed because the check on \(target.displayName) failed." }
            let verb = names.count == 1 ? "isn't" : "aren't"
            return "Nothing was removed because \(list(names)) \(verb) on \(target.displayName)."
        }
        let installFailed = rows.contains { row in
            guard row.operation == .install, row.title != run.checkTitle else { return false }
            if case .failed = row.state { return true }
            return false
        }
        if check?.state == .succeeded && installFailed {
            return "Nothing was removed because an install on \(target.displayName) failed."
        }
        return "Nothing was removed because the move was cancelled."
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
