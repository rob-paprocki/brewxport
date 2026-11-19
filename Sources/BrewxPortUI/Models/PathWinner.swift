import Foundation
import BrewxPortCore

/// Which copy of a command runs: the first PATH directory that holds a file with that name, the way a shell looks
/// it up. An engine wins only when that directory is its bin directory.
public enum PathWinner {
    /// The engine whose bin directory is the first directory in `path` holding a file named `command`. Nil when no
    /// directory holds it, or when the first one that does belongs to no engine in `binDirs` (a system copy runs).
    /// A trailing slash on either side doesn't matter.
    public static func winner(command: String, path: [String], binDirs: [EngineID: String],
                              exists: (String) -> Bool) -> EngineID? {
        guard let first = firstDirectory(holding: command, path: path, exists: exists) else { return nil }
        // Several engines can share a directory (Homebrew and mas); pick in a fixed order, never dictionary order.
        return binDirs.filter { normalized($0.value) == first }.keys.sorted { $0.rawValue < $1.rawValue }.first
    }

    /// The first directory in `path` that holds a file named `command`, without a trailing slash.
    public static func firstDirectory(holding command: String, path: [String], exists: (String) -> Bool) -> String? {
        guard !command.isEmpty, !command.contains("/") else { return nil }
        for entry in path {
            let dir = normalized(entry)
            if exists(dir == "/" ? "/" + command : dir + "/" + command) { return dir }
        }
        return nil
    }

    static func normalized(_ dir: String) -> String {
        var dir = dir
        while dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        return dir
    }
}
