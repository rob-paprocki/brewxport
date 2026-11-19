import Foundation
import BrewxPortCore

/// Everything the root helper checks before it runs `port`. Pure apart from the injected file-system reads,
/// so all of it is unit-tested; treat every input as hostile.
public enum HelperRequestValidator {
    public static let portPath = "/opt/local/bin/port"

    /// `port` is a Tcl script. Its interpreter must sit in MacPorts' own root-owned libexec directory.
    public static let interpreterDirectory = "/opt/local/libexec/macports/bin/"

    /// Argv caps. The largest real command is `-N`, a verb, six flags and a few names or variants, far below
    /// these; anything longer is refused rather than parsed.
    public static let maxArguments = 64
    public static let maxTokenBytes = 256

    /// The only `port` actions the helper runs.
    public static let verbs: Set<String> = ["install", "upgrade", "uninstall", "selfupdate"]

    /// Refuses anything but `["-N", verb] + extraArgs + names + variants`, where extraArgs come from
    /// `RootArguments.macPortsExtraArgs`, names pass `RootArguments.isValidPortName`, variants pass
    /// `RootArguments.isValidVariant` and appear only for `install`, and `selfupdate` takes no names.
    /// This is the layout `MacPortsEngine.command(for:)` builds. Throws `HelperError.notAllowed`.
    public static func validate(arguments: [String]) throws {
        guard arguments.count <= maxArguments else {
            throw HelperError.notAllowed("more than \(maxArguments) arguments")
        }
        for token in arguments {
            if token.isEmpty { throw HelperError.notAllowed("(empty argument)") }
            if token.utf8.contains(0) { throw HelperError.notAllowed(printable(token)) }
            if token.utf8.count > maxTokenBytes { throw HelperError.notAllowed(printable(token)) }
        }
        guard arguments.first == "-N" else {
            throw HelperError.notAllowed(arguments.first.map(printable) ?? "(no arguments)")
        }
        guard arguments.count >= 2 else { throw HelperError.notAllowed("(no action after -N)") }
        let verb = arguments[1]
        guard verbs.contains(verb) else { throw HelperError.notAllowed(printable(verb)) }

        let rest = arguments.dropFirst(2)
        var i = rest.startIndex
        var extraArgs: [String] = [], names: [String] = [], variants: [String] = []
        while i < rest.endIndex, RootArguments.macPortsExtraArgs.contains(rest[i]) { extraArgs.append(rest[i]); i += 1 }
        while i < rest.endIndex, RootArguments.isValidPortName(rest[i]) { names.append(rest[i]); i += 1 }
        if verb == "install" {
            while i < rest.endIndex, RootArguments.isValidVariant(rest[i]) { variants.append(rest[i]); i += 1 }
        }
        // Anything left is out of place or classifies as nothing allowed.
        if i < rest.endIndex { throw HelperError.notAllowed(printable(rest[i])) }

        if verb == "selfupdate" {
            if let name = names.first { throw HelperError.notAllowed(printable(name)) }
        } else if names.isEmpty {
            throw HelperError.notAllowed("\(verb) without a port name")
        }
        // Belt and braces: the same check the app ran before sending.
        do {
            try RootArguments.validateMacPorts(names: names, variants: variants, extraArgs: extraArgs)
        } catch let e as EngineError {
            throw HelperError.notAllowed(e.message)
        }
    }

    /// Refuses `path` unless it's a regular file owned by root with no group or other write bit, and every
    /// directory above it (`/`, `/opt`, `/opt/local`, `/opt/local/bin`) is a real directory, owned by root and
    /// not group- or other-writable. A symbolic link anywhere is refused, not followed, so `attributes` must
    /// have lstat semantics (`FileManager.attributesOfItem` does). Throws `HelperError.badExecutable`.
    public static func validateExecutable(atPath path: String,
                                          attributes: (String) throws -> [FileAttributeKey: Any]) throws {
        guard isCanonicalAbsolute(path) else {
            throw HelperError.badExecutable("\(printable(path)) isn't a plain absolute path")
        }
        let components = path.split(separator: "/").map(String.init)
        var ancestors = ["/"]
        for n in 1..<components.count {
            ancestors.append("/" + components[0..<n].joined(separator: "/"))
        }
        for dir in ancestors {
            try check(dir, expect: .typeDirectory, attributes: attributes)
        }
        try check(path, expect: .typeRegular, attributes: attributes)
    }

    /// The interpreter on `port`'s `#!` line. It must be a single canonical path inside `interpreterDirectory`
    /// with no arguments, on a complete first line. Throws `HelperError.badExecutable`.
    public static func interpreterPath(scriptHead: Data) throws -> String {
        guard scriptHead.starts(with: Array("#!".utf8)), let newline = scriptHead.firstIndex(of: 0x0A),
              let line = String(data: scriptHead[scriptHead.startIndex.advanced(by: 2)..<newline], encoding: .utf8)
        else { throw HelperError.badExecutable("\(portPath) has no readable #! line") }
        let path = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        guard path.hasPrefix(interpreterDirectory), isCanonicalAbsolute(path),
              !path.contains(" "), !path.contains("\t")
        else { throw HelperError.badExecutable("\(portPath) names an unexpected interpreter: \(printable(path))") }
        return path
    }

    /// `validateExecutable` for `port`, then for the interpreter its `#!` line names. Production passes
    /// `fileSystemAttributes` and `readScriptHead`. The Tcl libraries the interpreter loads live under the
    /// same root-owned `/opt/local` prefix; they are not walked one by one.
    public static func validateInstallation(attributes: (String) throws -> [FileAttributeKey: Any],
                                            readHead: (String) throws -> Data) throws {
        try validateExecutable(atPath: portPath, attributes: attributes)
        let head: Data
        do { head = try readHead(portPath) } catch {
            throw HelperError.badExecutable("\(portPath) can't be read")
        }
        try validateExecutable(atPath: try interpreterPath(scriptHead: head), attributes: attributes)
    }

    // MARK: production file-system access

    /// lstat semantics: a symbolic link is reported as `.typeSymbolicLink`, not followed.
    public static func fileSystemAttributes(_ path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }

    /// The first 512 bytes of `path`, opened without following a symbolic link.
    public static func readScriptHead(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 512)
        var n: Int
        repeat {
            n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        } while n < 0 && errno == EINTR
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Data(buffer[0..<n])
    }

    // MARK: private

    private static func check(_ path: String, expect: FileAttributeType,
                              attributes: (String) throws -> [FileAttributeKey: Any]) throws {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try attributes(path) } catch {
            throw HelperError.badExecutable("\(path) can't be inspected")
        }
        let type: FileAttributeType?
        if let t = attrs[.type] as? FileAttributeType { type = t }
        else if let s = attrs[.type] as? String { type = FileAttributeType(rawValue: s) }
        else { type = nil }
        guard let type else { throw HelperError.badExecutable("\(path) has no file type") }
        if type == .typeSymbolicLink { throw HelperError.badExecutable("\(path) is a symbolic link") }
        guard type == expect else {
            throw HelperError.badExecutable("\(path) isn't a \(expect == .typeDirectory ? "directory" : "regular file")")
        }
        guard let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue,
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue
        else { throw HelperError.badExecutable("\(path) has no owner or permissions") }
        guard owner == 0 else { throw HelperError.badExecutable("\(path) is owned by uid \(owner), not root") }
        guard mode & 0o022 == 0 else {
            throw HelperError.badExecutable("\(path) is group- or other-writable (mode \(String(mode, radix: 8)))")
        }
    }

    /// Starts with `/`, isn't `/` itself, and has no empty, `.` or `..` components.
    private static func isCanonicalAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return false }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// A short, log-safe rendering of a hostile token.
    private static func printable(_ token: String) -> String {
        let escaped = token.unicodeScalars.map { s -> String in
            s.value < 0x20 || s.value == 0x7F ? String(format: "\\x%02X", s.value) : String(s)
        }.joined()
        return escaped.count > 64 ? String(escaped.prefix(64)) + "…" : escaped
    }
}
