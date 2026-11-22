import Foundation

/// A Brewfile as BrewxPort reads it. Every line is exactly one of: an entry, an unhandled line, or a blank or
/// whole-comment line counted in `ignoredCount`. Nothing is dropped.
public struct BrewfileDocument: Equatable, Sendable {
    /// Lines BrewxPort can install, in file order. Each passed `BundleRules.check`.
    public var entries: [BrewfileEntry]
    /// Lines BrewxPort doesn't handle, in line order, with the reason.
    public var unhandled: [UnhandledLine]
    /// Blank and whole-comment lines, including those inside a Ruby block or a continuing statement.
    public var ignoredCount: Int
    /// Lines in the file. A final line break doesn't start another line.
    public var lineCount: Int

    public init(entries: [BrewfileEntry], unhandled: [UnhandledLine], ignoredCount: Int, lineCount: Int) {
        self.entries = entries
        self.unhandled = unhandled
        self.ignoredCount = ignoredCount
        self.lineCount = lineCount
    }
}

public struct BrewfileEntry: Equatable, Sendable {
    /// 1-based.
    public var line: Int
    public var ref: PackageRef
    /// The name to show: the app name for mas, else the name as written.
    public var displayName: String

    public init(line: Int, ref: PackageRef, displayName: String) {
        self.line = line
        self.ref = ref
        self.displayName = displayName
    }
}

public struct UnhandledLine: Equatable, Sendable {
    /// 1-based.
    public var line: Int
    /// The line as written, for showing: control and format scalars (tabs excepted) escaped as `\u{…}`, at most
    /// `BundleFile.maxJSONPreview` scalars of the original plus "…".
    public var text: String
    /// Why, shown as is; never holds a raw control character.
    public var reason: String

    public init(line: Int, text: String, reason: String) {
        self.line = line
        self.text = text
        self.reason = reason
    }
}

public enum BrewfileError: Error, Equatable {
    /// The file isn't UTF-8 text.
    case notText
}

/// Reads a Brewfile with a conservative line classifier, not a Ruby parser. A Brewfile is untrusted: each line that
/// looks like a `brew`/`cask`/`tap`/`mas` entry still goes through `BundleRules.check`, and anything it can't be
/// sure of (Ruby logic, options, other kinds of lines) is kept as an `UnhandledLine` with the reason.
public enum BrewfileReader {
    static let continues = "statement continues on the next line"
    static let rubyLogic = "inside Ruby logic"
    static let commentBlock = "inside a =begin/=end comment"
    static let conditional = "conditional line"
    static let customURL = "tap from a custom URL"
    static let builtInTap = "Homebrew's built-in tap, nothing to add"
    static let unreadable = "BrewxPort couldn't read this line"

    /// Most lines a file may have, blank and comment lines included: room for `maxEntries` entries with a description
    /// comment and a blank line each.
    public static let maxLines = 4 * BundleFile.maxEntries

    /// Reads a file's bytes. Refuses (`BundleFileError.tooLarge`), as a whole rather than cutting it short, a file over
    /// `BundleFile.maxFileBytes` or `maxLines`, or one with more than `BundleFile.maxEntries` entries and unhandled
    /// lines together.
    public static func read(_ data: Data) throws -> BrewfileDocument {
        guard data.count <= BundleFile.maxFileBytes else { throw BundleFileError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw BrewfileError.notText }
        let lines = splitLines(text)
        guard lines.count <= maxLines else { throw BundleFileError.tooLarge }
        let doc = read(lines: lines)
        guard doc.entries.count + doc.unhandled.count <= BundleFile.maxEntries else { throw BundleFileError.tooLarge }
        return doc
    }

    /// No size caps: tests only. Files from disk go through `read(_ data:)`.
    static func read(_ text: String) -> BrewfileDocument {
        read(lines: splitLines(text))
    }

    // MARK: lines

    private typealias Line = [Unicode.Scalar]

    /// Strips a leading BOM, treats CRLF as LF, and splits on LF only (Ruby's line break). A lone CR stays in its line.
    private static func splitLines(_ text: String) -> [Line] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var lines: [Line] = []
        var current: Line = []
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" {
                i += 1
                continue
            }
            if s == "\n" {
                lines.append(current)
                current = []
            } else {
                current.append(s)
            }
            i += 1
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" }

    private static func trimmed(_ line: Line) -> ArraySlice<Unicode.Scalar> {
        guard let start = line.firstIndex(where: { !isSpace($0) }) else { return [] }
        let end = line.lastIndex(where: { !isSpace($0) })!
        return line[start...end]
    }

    private static func isBlankOrComment(_ line: Line) -> Bool {
        let t = trimmed(line)
        return t.isEmpty || t.first == "#"
    }

    private static func hasPrefix(_ line: Line, _ prefix: String) -> Bool {
        let p = Array(prefix.unicodeScalars)
        guard line.count >= p.count, Array(line[0..<p.count]) == p else { return false }
        return line.count == p.count || isSpace(line[p.count])
    }

    // MARK: lexing

    /// Quote and bracket state carried from one line of a statement to the next.
    private struct LexState {
        var quote: Unicode.Scalar?
        var depth = 0
    }

    private struct Heredoc {
        var id: String
        /// `<<~ID` or `<<-ID`: the terminator may be indented. Plain `<<ID`: it must start in column 0.
        var indented: Bool
    }

    private struct Scan {
        /// The line before any comment, string contents included.
        var code: Line
        /// `code` with each string's contents removed (`"…"` becomes `""`), for finding words outside strings.
        var skeleton: Line
        /// Heredocs this line opens, in order; their bodies follow one after another.
        var heredocs: [Heredoc] = []
        /// Syntax this classifier can't track (a `%` literal, a regex or `/`, a backtick, a `?x` character literal,
        /// string interpolation), so quotes, brackets and words after it may be misread.
        var exotic = false
    }

    private static func isIdentStart(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || s == "_"
    }

    private static func isIdent(_ s: Unicode.Scalar) -> Bool { isIdentStart(s) || ("0"..."9").contains(s) }

    private static func lex(_ line: Line, _ state: inout LexState) -> Scan {
        var scan = Scan(code: [], skeleton: [])
        var i = 0
        while i < line.count {
            let s = line[i]
            let next: Unicode.Scalar? = i + 1 < line.count ? line[i + 1] : nil
            if let q = state.quote {
                scan.code.append(s)
                if s == "\\", let next {
                    scan.code.append(next)
                    i += 2
                    continue
                }
                if q == "\"", s == "#", next == "{" || next == "@" || next == "$" { scan.exotic = true }
                if s == q {
                    state.quote = nil
                    scan.skeleton.append(s)
                }
                i += 1
                continue
            }
            if s == "#" { break }
            if s == "<", next == "<", let (heredoc, after) = heredocID(line, from: i + 2) {
                scan.heredocs.append(heredoc)
                scan.exotic = true // a heredoc body can hold anything; nothing after it is trusted
                scan.code.append(contentsOf: line[i..<after])
                scan.skeleton.append(contentsOf: line[i..<after])
                i = after
                continue
            }
            switch s {
            case "/", "`": scan.exotic = true
            case "%": if let next, !isSpace(next), next != "=" { scan.exotic = true }
            case "?":
                // `mac?` is a method name. Any other `?` is a `?x` character literal or a ternary, whose `: x`
                // branch would read like a symbol.
                let before: Unicode.Scalar? = i > 0 ? line[i - 1] : nil
                if !(before.map(isIdent) ?? false) { scan.exotic = true }
            default: break
            }
            scan.code.append(s)
            scan.skeleton.append(s)
            switch s {
            case "\"", "'": state.quote = s
            case "(", "[", "{": state.depth += 1
            case ")", "]", "}": state.depth -= 1
            default: break
            }
            i += 1
        }
        if hasValuelessKey(scan.skeleton) { scan.exotic = true }
        return scan
    }

    /// Ruby 3.1 shorthand: `ident:` with no value (`{raise:}`, `f(exit:)`, or `exit:` ending the line) passes
    /// `ident`'s value, so it calls `ident`. `words` skips hash keys, so this is the only place it's seen. Spaces
    /// may come before the `,`, `)`, `]`, `}` or line end; a double colon is a scope, not a key.
    private static func hasValuelessKey(_ skeleton: Line) -> Bool {
        for i in skeleton.indices where skeleton[i] == ":" {
            guard i > 0, isIdent(skeleton[i - 1]) else { continue }
            if i + 1 < skeleton.count, skeleton[i + 1] == ":" { continue }
            var j = i + 1
            while j < skeleton.count, isSpace(skeleton[j]) { j += 1 }
            if j == skeleton.count || [",", ")", "]", "}"].contains(skeleton[j]) { return true }
        }
        return false
    }

    /// After `<<`: an optional `~` or `-`, then an identifier, bare or in matching quotes. Returns it and the index
    /// after it.
    private static func heredocID(_ line: Line, from start: Int) -> (Heredoc, Int)? {
        var i = start
        var indented = false
        if i < line.count, line[i] == "~" || line[i] == "-" {
            indented = true
            i += 1
        }
        var quote: Unicode.Scalar?
        if i < line.count, line[i] == "\"" || line[i] == "'" {
            quote = line[i]
            i += 1
        }
        guard i < line.count, isIdentStart(line[i]) else { return nil }
        var id = String.UnicodeScalarView()
        while i < line.count, isIdent(line[i]) {
            id.append(line[i])
            i += 1
        }
        if let q = quote {
            guard i < line.count, line[i] == q else { return nil }
            i += 1
        }
        return (Heredoc(id: String(id), indented: indented), i)
    }

    private static let continuingOperators: Set<Unicode.Scalar> =
        [",", "\\", "&", "|", "=", "?", ":", "+", "-", "*", ".", "<", ">", "^", "~"]
    private static let continuingWords: Set<String> = ["and", "or", "not", "if", "unless", "while", "until"]

    /// The statement goes on: an open quote or bracket, or the code ends in `,`, `\`, an operator (`&&`, `||`, `=`,
    /// `+`, `.`, …) or `and`/`or`/`not`/a trailing condition word. Not `mac?` (a method name) or `do |x|`.
    private static func isOpen(_ state: LexState, _ scan: Scan) -> Bool {
        if state.quote != nil || state.depth > 0 { return true }
        let code = Array(trimmed(scan.skeleton))
        guard let last = code.last else { return false }
        if last == "?" || last == "!" {
            return code.count < 2 || !isIdent(code[code.count - 2])
        }
        if last == "|" { return !endsWithBlockParameters(code) }
        if continuingOperators.contains(last) { return true }
        guard isIdent(last) else { return false }
        var start = code.count - 1
        while start > 0, isIdent(code[start - 1]) { start -= 1 }
        let word = String(String.UnicodeScalarView(code[start...]))
        guard start > 0, continuingWords.contains(word) else { return false }
        return code[start - 1] != "." && code[start - 1] != ":"
    }

    /// Ends in `do |x|` (or `{ |x|`, though that is already inside a bracket).
    private static func endsWithBlockParameters(_ code: [Unicode.Scalar]) -> Bool {
        guard code.count >= 2, let open = code.dropLast().lastIndex(of: "|") else { return false }
        let before = Array(trimmed(Array(code[..<open])))
        return before.suffix(2) == ["d", "o"] && (before.count == 2 || !isIdent(before[before.count - 3]))
    }

    /// The line goes on a statement from the line before: it starts with `.` (not `..`) or `&.`.
    private static func startsWithDot(_ line: Line) -> Bool {
        let t = Array(trimmed(line))
        if t.first == "." { return t.count < 2 || t[1] != "." }
        return t.count >= 2 && t[0] == "&" && t[1] == "."
    }

    // MARK: words

    private struct Word {
        var text: String
        /// Nearest non-space scalar before and the scalar right after, if any.
        var before: Unicode.Scalar?
        var after: Unicode.Scalar?
        var isFirst: Bool
        /// A method call on something (`.end`, `OS.mac?`): not a keyword, but still code.
        var isCall: Bool
    }

    /// Identifiers outside strings, skipping symbols (`:if`, written right after a lone `:`) and hash keys (`do:`).
    /// Method calls (`.end`) are kept and marked `isCall`.
    private static func words(_ skeleton: Line) -> [Word] {
        var out: [Word] = []
        var i = 0
        var lastNonSpace: Unicode.Scalar?
        var sawToken = false
        while i < skeleton.count {
            let s = skeleton[i]
            if isIdentStart(s) {
                let start = i
                var text = String.UnicodeScalarView()
                while i < skeleton.count, isIdent(skeleton[i]) {
                    text.append(skeleton[i])
                    i += 1
                }
                if i < skeleton.count, skeleton[i] == "?" || skeleton[i] == "!" {
                    text.append(skeleton[i])
                    i += 1
                }
                let after = i < skeleton.count ? skeleton[i] : nil
                let isSymbol = start > 0 && skeleton[start - 1] == ":" && (start < 2 || skeleton[start - 2] != ":")
                if !isSymbol && after != ":" {
                    out.append(Word(text: String(text), before: lastNonSpace, after: after, isFirst: !sawToken,
                                    isCall: lastNonSpace == "." || lastNonSpace == ":"))
                }
                sawToken = true
                lastNonSpace = text.last
                continue
            }
            if !isSpace(s) {
                lastNonSpace = s
                sawToken = true
            }
            i += 1
        }
        return out
    }

    private static let alwaysOpeners: Set<String> = ["case", "begin"]
    private static let firstWordOpeners: Set<String> = ["def", "class", "module", "for"]
    private static let conditionWords: Set<String> = ["if", "unless", "while", "until"]
    private static let loops: Set<String> = ["while", "until", "for"]

    /// A condition word opens a block at the start of a statement or right after an operator or opening bracket
    /// (`x = if y`); after a value it's a trailing modifier.
    private static func opensBlock(_ word: Word) -> Bool {
        if alwaysOpeners.contains(word.text) { return true }
        if firstWordOpeners.contains(word.text) { return word.isFirst }
        guard conditionWords.contains(word.text) else { return false }
        guard !word.isFirst, let before = word.before else { return true }
        return "=([{,|&!;".unicodeScalars.contains(before)
    }

    private struct Logic {
        var opens = 0
        var ends = 0
        var hasModifier = false
    }

    private static func logic(_ ws: [Word]) -> Logic {
        var result = Logic()
        var loopOpeners = 0
        var dos = 0
        for word in ws where !word.isCall {
            if word.text == "end" {
                result.ends += 1
            } else if word.text == "do" {
                dos += 1
            } else if opensBlock(word) {
                result.opens += 1
                if loops.contains(word.text) { loopOpeners += 1 }
            } else if conditionWords.contains(word.text) {
                result.hasModifier = true
            }
        }
        // `while x do` and `for x in y do`: the `do` belongs to the loop.
        result.opens += max(0, dos - loopOpeners)
        return result
    }

    // MARK: reading

    private enum Slot {
        case entry(PackageRef, String)
        case unhandled(String)
        case ignored
    }

    /// First words of statements BrewxPort can follow: Brewfile entry kinds (handled or not) and block structure.
    /// Any other first word is Ruby that may raise, exit, redefine `brew` or loop, so nothing after it is taken.
    private static let followableWords: Set<String> = [
        "brew", "cask", "tap", "mas", "cask_args", "vscode", "go", "cargo", "whalebrew", "uv", "npm", "krew",
        "flatpak", "winget",
        "if", "unless", "case", "begin", "end", "else", "elsif", "when", "then", "rescue", "ensure",
    ]
    /// Every identifier outside strings, symbols and hash keys in a followable statement must be one of these: the
    /// first words above, plain values and operators, and the platform checks real Brewfiles use in conditions.
    /// Anything else (`raise`, `exit`, `system`, `define_singleton_method`, `instance_eval`, …) may stop the file or
    /// change what `brew` means, so nothing after it is taken. `system` is left out on purpose: it runs a shell
    /// command, whose effects BrewxPort can't see, even inside a condition.
    private static let followableIdentifiers: Set<String> = followableWords.union([
        "then", "do", "and", "or", "not", "true", "false", "nil",
        "OS", "mac?", "linux?", "Hardware", "CPU", "arm?", "intel?", "MacOS", "ENV", "File", "exist?", "directory?",
    ])

    /// Whether BrewxPort can still tell which lines Ruby runs after this statement.
    private static func canFollow(_ ws: [Word]) -> Bool {
        guard let first = ws.first, first.isFirst, !first.isCall else { return false }
        if first.text == "ENV" {
            guard first.after == "[" else { return false }
        } else if !followableWords.contains(first.text) {
            return false
        }
        return ws.allSatisfy { followableIdentifiers.contains($0.text) }
    }

    private static func read(lines: [Line]) -> BrewfileDocument {
        let n = lines.count
        var slots = [Slot?](repeating: nil, count: n)
        var firstLine: [PackageRef: Int] = [:]
        var blockDepth = 0
        /// The first line of the first statement BrewxPort can't follow, 0-based. Lines it would accept after it are
        /// unhandled instead; lines already unhandled keep their own reason.
        var lostAt: Int?
        var i = 0

        while i < n {
            // `__END__`: Ruby stops reading here; the rest is data.
            if lines[i] == Array("__END__".unicodeScalars) {
                let end = i
                slots[i] = .unhandled("end of the Ruby code (`__END__`)")
                for j in (i + 1)..<max(i + 1, n) { slots[j] = .unhandled("after `__END__` (line \(end + 1))") }
                break
            }
            // `=begin` … `=end`: a Ruby comment block. Shown rather than hidden, since it often holds entry-like lines.
            if hasPrefix(lines[i], "=begin") {
                slots[i] = .unhandled(commentBlock)
                i += 1
                while i < n {
                    slots[i] = .unhandled(commentBlock)
                    i += 1
                    if hasPrefix(lines[i - 1], "=end") { break }
                }
                continue
            }
            if isBlankOrComment(lines[i]) {
                slots[i] = .ignored
                i += 1
                continue
            }

            // Gather the statement: this line plus every line it carries on to.
            var state = LexState()
            let start = i
            var group = [i]
            var scan = lex(lines[i], &state)
            var skeleton = scan.skeleton
            var exotic = scan.exotic
            var heredocs = scan.heredocs
            i += 1
            while i < n {
                if !heredocs.isEmpty {
                    // Each heredoc's body through its terminator is string content, one after another.
                    let heredoc = heredocs.removeFirst()
                    let terminator = Array(heredoc.id.unicodeScalars)
                    while i < n {
                        group.append(i)
                        i += 1
                        let line = lines[i - 1]
                        // Ruby allows leading whitespace before an indented terminator, never trailing.
                        let candidate = heredoc.indented ? Array(line.drop(while: isSpace)) : line
                        if candidate == terminator { break }
                    }
                    continue
                }
                var next = i
                if !isOpen(state, scan) {
                    // A later line starting with `.` or `&.` carries this statement on, comments in between.
                    while next < n, isBlankOrComment(lines[next]) { next += 1 }
                    guard next < n, startsWithDot(lines[next]) else { break }
                }
                if state.quote == nil, isBlankOrComment(lines[next]) {
                    while next < n, isBlankOrComment(lines[next]) { next += 1 }
                    for j in i..<next { slots[j] = .ignored }
                    i = next
                    continue
                }
                for j in i..<next { slots[j] = .ignored }
                group.append(next)
                scan = lex(lines[next], &state)
                skeleton.append(" ")
                skeleton.append(contentsOf: scan.skeleton)
                exotic = exotic || scan.exotic
                heredocs.append(contentsOf: scan.heredocs)
                i = next + 1
            }

            let ws = words(skeleton)
            let l = logic(ws)
            if lostAt == nil, exotic || !canFollow(ws) { lostAt = start }
            let reason: String?
            if blockDepth > 0 || l.opens > 0 {
                blockDepth = max(0, blockDepth + l.opens - l.ends)
                reason = rubyLogic
            } else if group.count > 1 {
                reason = continues
            } else if l.hasModifier {
                reason = conditional
            } else {
                switch classify(trimmed(lines[group[0]])) {
                case .rejected(let r):
                    reason = r
                case .accepted(let ref, let shown):
                    if let lost = lostAt {
                        reason = "after Ruby code BrewxPort can't follow (line \(lost + 1))"
                    } else if let first = firstLine[ref] {
                        reason = "listed twice (line \(first + 1))"
                    } else {
                        firstLine[ref] = group[0]
                        slots[group[0]] = .entry(ref, shown)
                        reason = nil
                    }
                }
            }
            if let reason {
                for index in group { slots[index] = .unhandled(reason) }
            }
        }

        var entries: [BrewfileEntry] = []
        var unhandled: [UnhandledLine] = []
        var ignored = 0
        for (index, slot) in slots.enumerated() {
            switch slot {
            case .entry(let ref, let shown):
                entries.append(BrewfileEntry(line: index + 1, ref: ref, displayName: shown))
            case .unhandled(let reason):
                unhandled.append(UnhandledLine(line: index + 1, text: displayText(lines[index]), reason: reason))
            case .ignored:
                ignored += 1
            case nil:
                assertionFailure("Brewfile line \(index + 1) wasn't classified")
                unhandled.append(UnhandledLine(line: index + 1, text: displayText(lines[index]), reason: unreadable))
            }
        }
        assert(entries.count + unhandled.count + ignored == n)
        return BrewfileDocument(entries: entries, unhandled: unhandled, ignoredCount: ignored, lineCount: n)
    }

    private static func displayText(_ line: Line) -> String {
        BundleRules.escaped(String(String.UnicodeScalarView(line)), limit: BundleFile.maxJSONPreview, keepTabs: true)
    }

    // MARK: entries

    private enum Verdict {
        case accepted(PackageRef, String)
        case rejected(String)
    }

    private static let entryWords: Set<String> = ["brew", "cask", "tap", "mas"]

    /// One complete, unconditional, single-line statement outside any Ruby block.
    private static func classify(_ line: ArraySlice<Unicode.Scalar>) -> Verdict {
        let scalars = Array(line)
        var i = 0
        guard i < scalars.count, isIdentStart(scalars[i]) else { return .rejected(unreadable) }
        var word = String.UnicodeScalarView()
        while i < scalars.count, isIdent(scalars[i]) {
            word.append(scalars[i])
            i += 1
        }
        let keyword = String(word)
        guard entryWords.contains(keyword) else {
            return .rejected("BrewxPort doesn't handle `\(BundleRules.shown(keyword))` lines")
        }

        // `brew "x"` or `brew("x")`; the comment, if any, is cut off first.
        var state = LexState()
        var rest = Array(lex(Array(scalars[i...]), &state).code)
        while let last = rest.last, isSpace(last) { rest.removeLast() }
        if rest.first == "(" {
            guard rest.last == ")" else { return .rejected(unreadable) }
            rest = Array(rest.dropFirst().dropLast())
        } else {
            guard let first = rest.first, isSpace(first) else { return .rejected(unreadable) }
        }
        guard let args = arguments(rest) else { return .rejected(unreadable) }

        // Ruby keeps the last of two equal keys, so a repeated key can't be read either way.
        var seenKeys = Set<String>()
        for (key, _) in args.options where !seenKeys.insert(key).inserted {
            return .rejected("has the option `\(BundleRules.shown(key))` twice")
        }
        let allowed: Set<String> = keyword == "mas" ? ["id"] : []
        // Homebrew 7 dumps third-party formulae as `brew "user/repo/name", trusted: true`. Installing by the qualified
        // name already says which tap the package comes from, so this exact shape is taken as a plain entry; any other
        // use of `trusted` stays unhandled. (The preview notes a third-party source only while its tap isn't added.)
        let trustedIsNoOp = (keyword == "brew" || keyword == "cask") && args.options.count == 1
            && args.options[0].key == "trusted" && args.options[0].value == "true"
            && args.strings.count == 1 && isThirdPartyQualified(args.strings[0])
        let refusedKeys = args.options.map(\.key).filter { !allowed.contains($0) && !(trustedIsNoOp && $0 == "trusted") }
        if !refusedKeys.isEmpty {
            let shownKeys = refusedKeys.prefix(5).map { "`\(BundleRules.shown($0))`" }
            return .rejected("has options BrewxPort doesn't apply: " + shownKeys.joined(separator: ", ")
                + (refusedKeys.count > 5 ? ", …" : ""))
        }

        let strings = args.strings
        let checked: BundleVerdict
        switch keyword {
        case "brew", "cask":
            guard strings.count == 1 else { return .rejected(unreadable) }
            checked = BundleRules.check(engine: .homebrew, kind: keyword == "brew" ? .formula : .cask, name: strings[0],
                                        displayName: nil, variants: [], extraArgs: [])
        case "tap":
            guard strings.count == 1 || strings.count == 2 else { return .rejected(unreadable) }
            let name = strings[0]
            if BundleRules.builtInTaps.contains(name.lowercased()) { return .rejected(builtInTap) }
            checked = BundleRules.check(engine: .homebrew, kind: .tap, name: name, displayName: nil, variants: [],
                                        extraArgs: [])
            if case .accepted = checked, strings.count == 2, !isDefaultURL(strings[1], tap: name) {
                return .rejected(customURL)
            }
        default: // mas
            guard strings.count == 1, let id = args.options.first(where: { $0.key == "id" })?.value else {
                return .rejected(unreadable)
            }
            if id.count > 1, id.hasPrefix("0") {
                return .rejected("app id “\(BundleRules.shown(id))” starts with 0, which Ruby reads as octal")
            }
            checked = BundleRules.check(engine: .mas, kind: .app, name: id, displayName: strings[0], variants: [],
                                        extraArgs: [])
        }
        switch checked {
        case .rejected(let reason): return .rejected(reason)
        case .accepted(let ref, let shown, _): return .accepted(ref, shown)
        }
    }

    /// `user/repo/name` with a tap other than Homebrew's own `homebrew/core` and `homebrew/cask`.
    static func isThirdPartyQualified(_ name: String) -> Bool {
        guard let tap = BundleRules.tapPrefix(name) else { return false }
        return !BundleRules.builtInTaps.contains(tap)
    }

    /// `https://github.com/<user>/homebrew-<repo>`, with an optional `.git`, any case.
    private static func isDefaultURL(_ url: String, tap: String) -> Bool {
        let parts = tap.split(separator: "/")
        guard parts.count == 2 else { return false }
        let expected = "https://github.com/\(parts[0])/homebrew-\(parts[1])".lowercased()
        let given = url.lowercased()
        return given == expected || given == expected + ".git"
    }

    private struct Arguments {
        var strings: [String] = []
        var options: [(key: String, value: String)] = []
    }

    /// Positional string literals, then `key: value` options, split on top-level commas. nil for anything else.
    private static func arguments(_ scalars: [Unicode.Scalar]) -> Arguments? {
        var pieces: [ArraySlice<Unicode.Scalar>] = []
        var state = LexState()
        var start = 0
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if let q = state.quote {
                if s == "\\" { i += 1 } else if s == q { state.quote = nil }
            } else {
                switch s {
                case "\"", "'": state.quote = s
                case "(", "[", "{": state.depth += 1
                case ")", "]", "}": state.depth -= 1
                case "," where state.depth == 0:
                    pieces.append(scalars[start..<i])
                    start = i + 1
                default: break
                }
            }
            i += 1
        }
        guard state.quote == nil, state.depth == 0 else { return nil }
        pieces.append(scalars[start..<scalars.count])

        var args = Arguments()
        for piece in pieces {
            let arg = Array(trimmed(Array(piece)))
            guard !arg.isEmpty else { return nil }
            if let string = stringLiteral(arg) {
                guard args.options.isEmpty else { return nil }
                args.strings.append(string)
            } else if let option = option(arg) {
                args.options.append(option)
            } else {
                return nil
            }
        }
        return args.strings.isEmpty ? nil : args
    }

    /// `"text"` or `'text'` with no backslash, no other quote of the same kind, and (double quotes) no `#{`.
    private static func stringLiteral(_ arg: [Unicode.Scalar]) -> String? {
        guard arg.count >= 2, let q = arg.first, q == "\"" || q == "'", arg.last == q else { return nil }
        let body = arg[1..<(arg.count - 1)]
        guard !body.contains(q), !body.contains("\\") else { return nil }
        if q == "\"", zip(body, body.dropFirst()).contains(where: { $0 == "#" && ["{", "@", "$"].contains($1) }) {
            return nil
        }
        return String(String.UnicodeScalarView(body))
    }

    /// `key: value`, with a non-empty value.
    private static func option(_ arg: [Unicode.Scalar]) -> (key: String, value: String)? {
        guard let first = arg.first, isIdentStart(first) else { return nil }
        var i = 0
        while i < arg.count, isIdent(arg[i]) { i += 1 }
        guard i < arg.count, arg[i] == ":", i + 1 < arg.count, isSpace(arg[i + 1]) else { return nil }
        let value = Array(trimmed(Array(arg[(i + 1)...])))
        guard !value.isEmpty else { return nil }
        return (String(String.UnicodeScalarView(arg[0..<i])), String(String.UnicodeScalarView(value)))
    }
}
