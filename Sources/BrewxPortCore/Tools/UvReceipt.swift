import Foundation

/// uv's record of one tool (`<tool dir>/<name>/uv-receipt.toml`), as much as a Repair needs to install the tool again
/// exactly as it was asked for (R28): its requirements (the tool itself, then its `--with` packages, each with extras
/// and a version requirement), the Python it was asked for, and whether anything else was recorded that BrewxPort
/// doesn't pass back (a source that isn't the index, a marker, constraints, overrides, index or resolver settings,
/// commands from other packages). The file stays when the tool's Python is gone, which is when uv's own list leaves
/// the tool out.
///
/// The receipt is TOML; this reads only the subset uv writes for it (tables, `key = value` with strings, booleans,
/// arrays and inline tables). Anything else makes the receipt unreadable, never half-read.
struct UvReceipt: Equatable, Sendable {
    /// One requirement as uv recorded it.
    struct Requirement: Equatable, Sendable {
        let name: String
        /// The version requirement as written (`>=24, <24.3.0`); nil for none.
        let specifier: String?
        let extras: [String]
        /// Recorded keys besides `name`, `specifier` and `extras` (`git`, `url`, `path`, `directory`, `editable`,
        /// `marker`, `index`…).
        let otherKeys: Set<String>
    }

    let requirements: [Requirement]
    /// `python = "3.12"`: the Python the tool was installed for, as asked.
    let python: String?
    /// The packages its commands come from (`entrypoints`' `from`), other than the tool itself when that's all.
    let commandsFrom: Set<String>
    /// Constraints, overrides or build constraints were recorded.
    let hasConstraints: Bool
    /// `[tool.options]` has a setting (an index, a resolution strategy, exclude-newer…): a value that isn't empty
    /// (an empty string, list or table, or `false`, is uv's default, not a setting).
    let hasOptions: Bool

    /// A value that sets something: a string, list or table that isn't empty (a table with a setting in it), or `true`.
    static func isSetting(_ value: TOMLSubset.Value) -> Bool {
        switch value {
        case .string(let text): return !text.isEmpty
        case .bool(let on): return on
        case .array(let items): return !items.isEmpty
        case .table(let fields): return fields.values.contains(where: isSetting)
        }
    }

    /// The receipt in `text`; nil when it isn't one BrewxPort can read in full.
    init?(_ text: String) {
        guard let tables = TOMLSubset.parse(text), let tool = tables["tool"] else { return nil }
        var requirements: [Requirement] = []
        for value in tool["requirements"]?.array ?? [] {
            guard let table = value.table, let name = table["name"]?.string else { return nil }
            var extras: [String] = []
            if let listed = table["extras"] {
                guard let names = listed.array?.compactMap(\.string), names.count == listed.array?.count else {
                    return nil
                }
                extras = names
            }
            if table["specifier"] != nil, table["specifier"]?.string == nil { return nil }
            requirements.append(Requirement(name: name, specifier: table["specifier"]?.string, extras: extras,
                                            otherKeys: Set(table.keys).subtracting(["name", "specifier", "extras"])))
        }
        guard tool["requirements"] == nil || tool["requirements"]?.array != nil else { return nil }
        self.requirements = requirements
        if let python = tool["python"] {
            guard let text = python.string else { return nil }
            self.python = text
        } else {
            python = nil
        }
        var from: Set<String> = []
        for value in tool["entrypoints"]?.array ?? [] {
            guard let table = value.table else { return nil }
            if let source = table["from"] {
                guard let name = source.string else { return nil }
                from.insert(name)
            }
        }
        commandsFrom = from
        hasConstraints = ["constraints", "overrides", "build-constraint-dependencies"].contains {
            !(tool[$0]?.array?.isEmpty ?? true) || (tool[$0] != nil && tool[$0]?.array == nil)
        }
        hasOptions = (tables["tool.options"] ?? [:]).values.contains(where: Self.isSetting)
    }
}

/// The part of TOML that uv's receipts use: `[table]` headers, and `key = value` lines whose value is a string (basic
/// or literal), a boolean, an array or an inline table, each of those as deep as needed, an array spread over lines
/// included. Comments and blank lines are skipped. Numbers, dates, dotted keys, multi-line strings and repeated keys
/// aren't read: a file with any of them reads as nil.
enum TOMLSubset {
    indirect enum Value: Equatable, Sendable {
        case string(String)
        case bool(Bool)
        case array([Value])
        case table([String: Value])

        var string: String? { if case .string(let text) = self { text } else { nil } }
        var array: [Value]? { if case .array(let items) = self { items } else { nil } }
        var table: [String: Value]? { if case .table(let fields) = self { fields } else { nil } }
    }

    /// Table name (`tool`, `tool.options`; "" for keys before any header) → its keys.
    static func parse(_ text: String) -> [String: [String: Value]]? {
        var reader = Reader(Array(text.unicodeScalars))
        var tables: [String: [String: Value]] = [:]
        var current = ""
        while true {
            reader.skipBlankLinesAndComments()
            guard !reader.atEnd else { break }
            if reader.peek == "[" {
                reader.advance()
                guard let name = reader.tableName(), reader.lineEnds() else { return nil }
                guard tables[name] == nil else { return nil }
                tables[name] = [:]
                current = name
                continue
            }
            guard let key = reader.key(), reader.expect("="), let value = reader.value(), reader.lineEnds() else {
                return nil
            }
            guard tables[current]?[key] == nil else { return nil }
            tables[current, default: [:]][key] = value
        }
        return tables
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        var peek: Unicode.Scalar? { atEnd ? nil : scalars[index] }
        mutating func advance() { index += 1 }

        mutating func skipSpaces() {
            while let c = peek, c == " " || c == "\t" { advance() }
        }

        /// Spaces, new lines and comments, as between array items.
        mutating func skipBlankLinesAndComments() {
            while let c = peek {
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    advance()
                } else if c == "#" {
                    while let d = peek, d != "\n" { advance() }
                } else {
                    return
                }
            }
        }

        /// The rest of the line is blank or a comment.
        mutating func lineEnds() -> Bool {
            skipSpaces()
            if peek == "#" { while let c = peek, c != "\n" { advance() } }
            guard let c = peek else { return true }
            return c == "\n" || c == "\r"
        }

        mutating func expect(_ c: Unicode.Scalar) -> Bool {
            skipSpaces()
            guard peek == c else { return false }
            advance()
            return true
        }

        /// `tool` or `tool.options` and the closing `]`.
        mutating func tableName() -> String? {
            var parts: [String] = []
            while true {
                skipSpaces()
                guard let part = bareKey() else { return nil }
                parts.append(part)
                skipSpaces()
                guard peek == "." else { break }
                advance()
            }
            guard peek == "]" else { return nil }
            advance()
            return parts.joined(separator: ".")
        }

        mutating func bareKey() -> String? {
            var key = ""
            while let c = peek, CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-" {
                key.unicodeScalars.append(c)
                advance()
            }
            return key.isEmpty ? nil : key
        }

        /// A bare or quoted key.
        mutating func key() -> String? {
            skipSpaces()
            if peek == "\"" || peek == "'" { return quoted() }
            return bareKey()
        }

        mutating func value() -> Value? {
            skipSpaces()
            switch peek {
            case "\""?, "'"?: return quoted().map(Value.string)
            case "["?:
                advance()
                var items: [Value] = []
                while true {
                    skipBlankLinesAndComments()
                    if peek == "]" { advance(); return .array(items) }
                    guard let item = value() else { return nil }
                    items.append(item)
                    skipBlankLinesAndComments()
                    if peek == "," { advance(); continue }
                    guard peek == "]" else { return nil }
                }
            case "{"?:
                advance()
                var fields: [String: Value] = [:]
                skipSpaces()
                if peek == "}" { advance(); return .table(fields) }
                while true {
                    guard let key = key(), expect("="), let item = value(), fields[key] == nil else { return nil }
                    fields[key] = item
                    skipSpaces()
                    if peek == "," { advance(); continue }
                    guard peek == "}" else { return nil }
                    advance()
                    return .table(fields)
                }
            default:
                if word("true") { return .bool(true) }
                if word("false") { return .bool(false) }
                return nil
            }
        }

        mutating func word(_ text: String) -> Bool {
            let wanted = Array(text.unicodeScalars)
            guard index + wanted.count <= scalars.count, Array(scalars[index..<index + wanted.count]) == wanted
            else { return false }
            index += wanted.count
            return true
        }

        /// A basic string (`"…"`, with `\"`, `\\`, `\n`, `\t`, `\r`, `\uXXXX` and `\UXXXXXXXX` escapes) or a literal
        /// one (`'…'`), on one line.
        mutating func quoted() -> String? {
            guard let quote = peek else { return nil }
            advance()
            var text = ""
            while let c = peek {
                advance()
                if c == "\n" { return nil }
                if c == quote { return text }
                guard quote == "\"", c == "\\" else {
                    text.unicodeScalars.append(c)
                    continue
                }
                guard let escape = peek else { return nil }
                advance()
                switch escape {
                case "\"": text += "\""
                case "\\": text += "\\"
                case "n": text += "\n"
                case "t": text += "\t"
                case "r": text += "\r"
                case "u", "U":
                    let count = escape == "u" ? 4 : 8
                    guard index + count <= scalars.count else { return nil }
                    let hex = String(String.UnicodeScalarView(scalars[index..<index + count]))
                    guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
                    text.unicodeScalars.append(scalar)
                    index += count
                default:
                    return nil
                }
            }
            return nil
        }
    }
}
