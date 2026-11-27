import Foundation
import BrewxPortCore

/// Adds one package manager's bin directory to the person's PATH, only when they click "Add to PATH" in the move
/// preview. zsh gets the line in ~/.zprofile (or $ZDOTDIR/.zprofile, see `zshDestination`) and bash in
/// ~/.bash_profile (see `bashDestination`); any other shell (or none known) is offered the line to copy instead, and
/// nothing is written.
///
/// The line is always `export PATH="<bin>:$PATH"  # Added by BrewxPort`, and only a known engine bin directory
/// (`EngineLocator`'s candidates on either architecture, or a language engine's own bin folder that the caller names
/// and that is a plain path, `isPlainPath`) is ever written, and only to the file the offer named. The
/// file is appended to and never rewritten: it's opened with O_APPEND and O_NOCTTY (created 0644 when missing),
/// checked on the open descriptor to be a regular file the person owns (a symlink to one is fine), given a trailing
/// newline first when it lacks one, and written in one call.
/// A file that already exports that directory in a PATH line (or has our line) is left alone. No shell runs.
public struct ShellPathEditor: Sendable {
    /// A file "Add to PATH" may append to. Only `offer` makes one, so `add` never writes anywhere an offer didn't
    /// name.
    public struct Target: Sendable, Equatable {
        /// As the person sees it (`~/.zprofile`).
        public let file: String
        /// The absolute path that's written.
        let path: String
    }

    /// What the preview can offer.
    public enum Offer: Sendable, Equatable {
        /// "Add to PATH" appends to this file.
        case append(Target)
        /// Show the line with a Copy button, and the file it probably belongs in when that's known.
        case copyOnly(hint: String?)
    }

    public enum Outcome: Sendable, Equatable {
        case added(file: String)
        case alreadyPresent(file: String)
    }

    public enum Failure: Error, Sendable, Equatable {
        case unknownDirectory
        case copyOnly
        case notARegularFile(file: String)
        case notYours(file: String)
        case couldNotWrite(file: String, reason: String)
    }

    /// Every engine's bin directory, on either architecture.
    public static let knownDirectories: Set<String> = {
        var dirs = Set<String>()
        for id in EngineID.allCases {
            for arch in [Arch.arm64, .x86_64] {
                for path in EngineLocator().candidates(for: id, arch: arch) {
                    dirs.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
                }
            }
        }
        return dirs
    }()

    public static let marker = "# Added by BrewxPort"

    private let home: URL
    private let shell: String?
    private let owner: uid_t

    /// home: the person's home directory. shell: their login shell (the path `LoginShellPath` asks). owner: who must
    /// own the file; tests change it.
    public init(home: URL, shell: String?, owner: uid_t = getuid()) {
        self.home = home
        self.shell = shell
        self.owner = owner
    }

    /// An editor that only ever offers the line to copy.
    public static let copyOnly = ShellPathEditor(home: URL(fileURLWithPath: "/nonexistent"), shell: nil)

    public static func line(for bin: String) -> String {
        "export PATH=\"\(trimmed(bin)):$PATH\"  \(marker)"
    }

    public static func isKnown(_ bin: String) -> Bool { knownDirectories.contains(trimmed(bin)) }

    /// An absolute path a shell reads as nothing but itself inside the line's double quotes: letters, digits, spaces
    /// and `/ . _ - + @`, with no `.` or `..` part. No `$`, backtick, quote, backslash, colon or control character,
    /// so a folder an engine reported can never become code in a startup file.
    public static func isPlainPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " /._-+@"))
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    public var offer: Offer {
        switch destination {
        case .file(let path, let shown): return .append(Target(file: shown, path: path))
        case .copy(let hint): return .copyOnly(hint: hint)
        }
    }

    /// Where the line goes: a file BrewxPort may append to, or only the line to copy (naming the file the person
    /// probably uses, when that's known).
    private enum Destination {
        case file(path: String, shown: String)
        case copy(hint: String?)
    }

    private var destination: Destination {
        switch shell.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
        case "zsh": return zshDestination
        case "bash": return bashDestination
        default: return .copy(hint: nil)
        }
    }

    /// ~/.bash_profile, unless it's missing and bash reads ~/.bash_login or ~/.profile instead: creating
    /// ~/.bash_profile would stop bash reading that one, so the line is only offered to copy into it.
    private var bashDestination: Destination {
        let profile = home.appendingPathComponent(".bash_profile").path
        if !Self.exists(profile) {
            for other in [".bash_login", ".profile"] where Self.exists(home.appendingPathComponent(other).path) {
                return .copy(hint: "~/" + other)
            }
        }
        return .file(path: profile, shown: "~/.bash_profile")
    }

    /// ~/.zprofile, or $ZDOTDIR/.zprofile when ~/.zshenv sets ZDOTDIR. That one is written only when ZDOTDIR is an
    /// existing directory inside the home folder that the person owns; otherwise the line is offered to copy. A
    /// .zshenv whose ZDOTDIR can't be read exactly is copy-only too, never ~/.zprofile: zsh may not read that file. So
    /// is a .zshenv that isn't a regular file (checked first, so a FIFO can't hang the read) or isn't UTF-8.
    private var zshDestination: Destination {
        let standard = Destination.file(path: home.appendingPathComponent(".zprofile").path, shown: "~/.zprofile")
        let zshenv = home.appendingPathComponent(".zshenv").path
        var zshenvInfo = stat()
        guard stat(zshenv, &zshenvInfo) == 0 else { return errno == ENOENT ? standard : .copy(hint: nil) }
        guard zshenvInfo.st_mode & S_IFMT == S_IFREG,
              let text = try? String(contentsOfFile: zshenv, encoding: .utf8) else { return .copy(hint: nil) }
        let setting: String
        switch Self.zdotdir(in: text) {
        case .notSet: return standard
        case .unreadable: return .copy(hint: nil)
        case .value(let value): setting = value
        }
        guard let value = Self.expand(setting, home: home.path) else { return .copy(hint: nil) }
        let dir = Self.trimmed(value)
        let homePath = Self.trimmed(home.path)
        let shownDir = dir == homePath ? "~" : dir.hasPrefix(homePath + "/")
            ? "~" + dir.dropFirst(homePath.count) : dir
        let shown = shownDir + "/.zprofile"
        let resolvedHome = Self.trimmed(home.resolvingSymlinksInPath().path)
        let resolvedDir = Self.trimmed(URL(fileURLWithPath: dir).resolvingSymlinksInPath().path)
        if resolvedDir == resolvedHome { return standard }
        guard resolvedDir.hasPrefix(resolvedHome + "/") else { return .copy(hint: shown) }
        var info = stat()
        guard stat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner else {
            return .copy(hint: shown)
        }
        return .file(path: dir + "/.zprofile", shown: shown)
    }

    /// What a .zshenv says about ZDOTDIR.
    enum ZdotdirSetting: Equatable {
        case notSet
        /// The last assignment's value, as written, quotes kept.
        case value(String)
        /// A line mentions ZDOTDIR in a way BrewxPort can't read exactly.
        case unreadable
    }

    /// The last ZDOTDIR assignment in a .zshenv. Only `ZDOTDIR=<value>` or `export ZDOTDIR=<value>` on a line of its
    /// own counts, where the value is one unquoted word without quotes or backslashes, or one '…' or "…" string
    /// without backslashes, followed by nothing but whitespace, a ` #` comment, or a `;` and commands that don't
    /// mention ZDOTDIR. A bare `export ZDOTDIR` is fine. Any other line that mentions ZDOTDIR, outside a comment,
    /// makes it unreadable.
    static func zdotdir(in text: String) -> ZdotdirSetting {
        var found = ZdotdirSetting.notSet
        for raw in text.split(whereSeparator: \.isNewline) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.contains("ZDOTDIR") else { continue }
            var line = Substring(trimmed)
            if line.hasPrefix("export ") { line = line.dropFirst("export ".count).drop(while: { $0 == " " }) }
            if line.hasPrefix("ZDOTDIR"), Self.endsCleanly(line.dropFirst("ZDOTDIR".count)) {
                continue  // a bare `export ZDOTDIR`
            }
            guard line.hasPrefix("ZDOTDIR="), let value = Self.assignedValue(line.dropFirst("ZDOTDIR=".count))
            else { return .unreadable }
            found = .value(value)
        }
        return found
    }

    /// The value at the start of `text` (quotes kept), or nil when it isn't one simple word or string followed by
    /// a clean end.
    private static func assignedValue(_ text: Substring) -> String? {
        if let quote = text.first, quote == "\"" || quote == "'" {
            let rest = text.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            let inside = rest[..<end]
            guard !inside.contains("\\"), endsCleanly(rest[rest.index(after: end)...]) else { return nil }
            return String(quote) + String(inside) + String(quote)
        }
        let word = text.prefix { !$0.isWhitespace && $0 != ";" }
        guard !word.contains(where: { "\"'\\".contains($0) }), endsCleanly(text.dropFirst(word.count)) else {
            return nil
        }
        return String(word)
    }

    /// Nothing, whitespace, whitespace then a `#` comment, or a `;` followed by commands that don't mention ZDOTDIR
    /// (a bare `export ZDOTDIR` aside).
    private static func endsCleanly(_ text: Substring) -> Bool {
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let rest = text.drop(while: blank)
        if rest.isEmpty { return true }
        if rest.first == "#" { return rest.startIndex != text.startIndex }
        guard rest.first == ";" else { return false }
        let after = rest.dropFirst().drop(while: blank)
        guard after.contains("ZDOTDIR") else { return true }
        return after.hasPrefix("export ZDOTDIR") && endsCleanly(after.dropFirst("export ZDOTDIR".count))
    }

    /// A ZDOTDIR value as an absolute path: quotes removed, a leading `~` replaced only when unquoted (as zsh does),
    /// and `$HOME` and `${HOME}` replaced outside single quotes. Nil for anything else that needs a shell to work out
    /// (other variables, command substitution) or isn't absolute.
    static func expand(_ value: String, home: String) -> String? {
        var path: String
        if value.hasPrefix("'") {
            path = String(value.dropFirst().dropLast())
        } else {
            let quoted = value.hasPrefix("\"")
            path = quoted ? String(value.dropFirst().dropLast()) : value
            if !quoted, path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
            path = path.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
            if path.contains("$") || path.contains("`") { return nil }
        }
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        return path
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// O_NONBLOCK so a FIFO can't hang the open, O_NOCTTY so a terminal can't become this process's controlling one.
    static let openFlags = O_RDWR | O_APPEND | O_NONBLOCK | O_NOCTTY | O_CLOEXEC
    static let createFlags = O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC

    /// Appends the line for `bin` to the file `offer` named (the one the preview showed, even if the files have
    /// changed since), unless that file already puts it on the PATH. A copy-only offer writes nothing. `allowing` are
    /// language engines' bin folders (`~/.cargo/bin`) the caller vouches for; each is written only when it's a plain
    /// path (`isPlainPath`).
    public func add(_ bin: String, to offer: Offer, allowing languageBins: Set<String> = []) throws(Failure) -> Outcome {
        let allowed = languageBins.map(Self.trimmed).contains(Self.trimmed(bin)) && Self.isPlainPath(bin)
        guard Self.isKnown(bin) || allowed else { throw .unknownDirectory }
        guard case .append(let target) = offer else { throw .copyOnly }
        let path = target.path, shown = target.file
        let bin = Self.trimmed(bin)

        var created = false
        var fd = open(path, Self.openFlags)
        if fd < 0 && errno == ENOENT {
            // Missing. A dangling symlink is refused rather than creating whatever it points at.
            var link = stat()
            if lstat(path, &link) == 0 { throw .notARegularFile(file: shown) }
            fd = open(path, Self.createFlags, 0o644)
            created = fd >= 0
        }
        guard fd >= 0 else {
            if errno == EISDIR { throw .notARegularFile(file: shown) }
            throw .couldNotWrite(file: shown, reason: Self.reason(errno))
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .couldNotWrite(file: shown, reason: Self.reason(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notARegularFile(file: shown) }
        guard info.st_uid == owner else { throw .notYours(file: shown) }
        if created { _ = fchmod(fd, 0o644) }

        let existing: Data
        do {
            existing = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            throw .couldNotWrite(file: shown, reason: error.localizedDescription)
        }
        let text = String(decoding: existing, as: UTF8.self)
        if Self.exports(bin, in: text) { return .alreadyPresent(file: shown) }

        var addition = Self.line(for: bin) + "\n"
        if let last = existing.last, last != UInt8(ascii: "\n") { addition = "\n" + addition }
        let bytes = Array(addition.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            throw .couldNotWrite(file: shown, reason: written < 0 ? Self.reason(errno) : "only part of the line was written")
        }
        return .added(file: shown)
    }

    /// Whether a line that isn't a comment sets PATH (or zsh's `path`) with `bin` as one whole entry.
    static func exports(_ bin: String, in text: String) -> Bool {
        let bounds = CharacterSet(charactersIn: "\"':=( )\t")
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), line.lowercased().contains("path") else { continue }
            var search = line.startIndex..<line.endIndex
            while let found = line.range(of: bin, range: search) {
                let before = found.lowerBound == line.startIndex ? nil : line[line.index(before: found.lowerBound)]
                let after = found.upperBound == line.endIndex ? nil : line[found.upperBound]
                let isBound = { (c: Character?) in c.map { $0.unicodeScalars.allSatisfy(bounds.contains) } ?? true }
                if isBound(before) && isBound(after) { return true }
                search = found.upperBound..<line.endIndex
            }
        }
        return false
    }

    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func reason(_ code: Int32) -> String { String(cString: strerror(code)) }
}
