import Foundation

/// Finds a language tool (npm, cargo, gem…) the way the user's shell would: the first match on the login shell's
/// PATH, then fixed install locations. GUI apps don't inherit the shell's PATH, so the caller passes the PATH
/// `LoginShellPath` captured.
///
/// Each folder is resolved with realpath (an fnm per-shell link becomes the Node version's own bin folder), but the
/// tool keeps its own file name: Homebrew's and nvm's `npm` are symlinks to `npm-cli.js`, whose folder holds no
/// `node`, and rustup's `cargo` is a link to `rustup` that only acts as cargo when started under that name.
public struct ToolLocator: Sendable {
    public init() {}

    /// The tool in the first folder of `loginPath`, then of `fixed`, that holds an executable file of that name, as
    /// `<realpath of the folder>/<tool>`. Folders that aren't absolute or don't exist are skipped. Nil when none has
    /// it, or when `tool` isn't a plain file name.
    public func locate(_ tool: String, loginPath: [String], fixed: [String]) -> URL? {
        guard !tool.isEmpty, tool != ".", tool != "..", !tool.contains("/") else { return nil }
        for folder in loginPath + fixed where folder.hasPrefix("/") {
            guard let real = Self.realPath(folder) else { continue }
            let candidate = URL(fileURLWithPath: real, isDirectory: true).appendingPathComponent(tool).path
            if Self.isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// `path` with every symlink and `.`/`..` resolved (realpath(3)); nil when it doesn't exist.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// An executable regular file (symlinks followed), as a shell's command lookup accepts: not a folder.
    static func isExecutableFile(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
