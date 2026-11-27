import Foundation

/// Takes credentials out of a language tool's output before BrewxPort shows it, logs it or puts it in a message.
///
/// pip, pipx, uv and npm print the index and registry URLs they use, and a private one's URL often carries a token: as
/// its user name and password (`https://__token__:<token>@host/simple`), or in its query. `RunSession` cleans every
/// output line of a language engine's step, and the language engines clean their own error messages
/// (`LanguageTool.failure`).
///
/// - Every URL (`scheme://…`) loses its user name and password, and its query: `https://user:token@host/simple?t=x`
///   becomes `https://host/simple`. A fragment (`#…`) stays.
///   - A URL ends at whitespace, a double quote, a backtick (uv wraps URLs in them), `<`, `>` or the next `scheme://`,
///     so two URLs side by side (`…/x,https://…`) are each cleaned. Its query also ends at a `'` or `)` after the `?`.
///   - The user name and password run to the last `@` before the host. A password with an unencoded `/`, `?`, `#`,
///     `'` or `)` goes too, as long as a `:` follows the user name; an `@` right after a `/` is part of a path
///     (npm's `https://registry.npmjs.org/@scope/name`), not a user name.
/// - A `NAME=value` whose name ends in `_PASSWORD`, `_TOKEN`, `_SECRET`, `_AUTH` or `_AUTHTOKEN` (any case:
///   `NPM_TOKEN`, `NODE_AUTH_TOKEN`, `UV_INDEX_<NAME>_PASSWORD`, `:_authToken`) has its value replaced by `***`, and so
///   does a `PIP_…=value` whose value has a URL with a user name, a password or a query. `name==version` isn't one.
///
/// Everything else stays exactly as it was. What can't be told apart: an unencoded `/` or port-like `:1234/` in a
/// password (`u:1234/secret@`, `tok/secret@`) reads like `host:8080/a@b` or `host/tool.git@v1.0`, so it isn't taken
/// out; and an unencoded `"` or whitespace in a password ends the URL there.
public enum CredentialScrubber {
    /// `text`, every line, with the credentials above taken out.
    public static func scrub(_ text: String) -> String {
        guard text.contains("=") || text.contains("://") else { return text }
        let named = withoutSecretValues(text)
        return named.contains("://") ? withoutURLCredentials(named) : named
    }

    // MARK: NAME=value

    /// A variable assignment: a name, one `=` (not `==`, a version: `google_auth==2.0`), and a quoted value or one
    /// running to whitespace (an unclosed quote or a quote inside included).
    private static let assignment = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=(?!=)("[^"]*"|'[^']*'|\S+)"#)

    /// The name endings whose values are secrets, lowercased.
    private static let secretSuffixes = ["_password", "_token", "_secret", "_auth", "_authtoken"]

    /// `text` with every secret variable's value replaced. A value that is itself an assignment
    /// (`--env=NPM_TOKEN=…`, `UV_INDEX=name=URL`) is looked into.
    private static func withoutSecretValues(_ text: String) -> String {
        guard text.contains("=") else { return text }
        return replacing(assignment, in: text) { match, text in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { return nil }
            let name = text[nameRange].lowercased()
            let value = String(text[valueRange])
            let secret = secretSuffixes.contains { name.hasSuffix($0) }
                || (name.hasPrefix("pip_") && withoutURLCredentials(value) != value)
            if secret { return text[nameRange] + "=***" }
            let inner = withoutSecretValues(value)
            return inner == value ? nil : text[nameRange] + "=" + inner
        }
    }

    // MARK: URLs

    /// Where a URL starts: its scheme and `://`.
    private static let scheme = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://"#)

    /// The characters a URL can't run past. Not `,`: it's legal in a password and a query (bundler's `?gems=a,b`).
    private static let urlEnds: Set<Character> = ["\"", "`", "<", ">"]
    /// The characters a query can't run past (a path, a user name or a password can).
    private static let queryEnds: Set<Character> = ["'", ")"]

    private static func withoutURLCredentials(_ text: String) -> String {
        let starts = scheme.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
        guard !starts.isEmpty else { return text }
        var result = ""
        var copied = text.startIndex
        for (index, start) in starts.enumerated() where start.lowerBound >= copied {
            let limit = index + 1 < starts.count ? starts[index + 1].lowerBound : text.endIndex
            let end = text[start.upperBound..<limit].firstIndex { $0.isWhitespace || urlEnds.contains($0) } ?? limit
            result += text[copied..<start.lowerBound]
            result += text[start] + cleaned(text[start.upperBound..<end])
            copied = end
        }
        result += text[copied...]
        return result
    }

    /// A URL's part after `scheme://`, without its user name, password and query.
    private static func cleaned(_ url: Substring) -> String {
        var rest = url
        // A user name with an unencoded `@` and a password with an unencoded `/` need two goes.
        for _ in 0..<3 {
            guard let end = userinfoEnd(rest) else { break }
            rest = rest[rest.index(after: end)...]
        }
        let fragment = rest.firstIndex(of: "#") ?? rest.endIndex
        guard let question = rest[..<fragment].firstIndex(of: "?") else { return String(rest) }
        // A `'` or `)` before the `?` is part of the path (`/fo(o)/x`); after it, it closes what the URL was in.
        let close = rest[question...].firstIndex { queryEnds.contains($0) } ?? rest.endIndex
        return String(rest[..<question] + rest[min(fragment, close)...])
    }

    /// The `@` that ends `url`'s user name and password, or nil when it has none.
    ///
    /// The authority runs to the first `/`, `?` or `#`; its last `@` ends them. Without one there, a `:` after the
    /// user name that isn't a port means the password itself may hold one of those: the first later `@` that doesn't
    /// follow a `/`, then the last `@` before the next `/`.
    private static func userinfoEnd(_ url: Substring) -> Substring.Index? {
        let authorityEnd = url.firstIndex { "/?#".contains($0) } ?? url.endIndex
        let authority = url[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") { return at }
        var host = authority
        if host.first == "[", let bracket = host.firstIndex(of: "]") { host = host[bracket...] }
        guard let colon = host.firstIndex(of: ":") else { return nil }
        let afterColon = host[host.index(after: colon)...]
        guard afterColon.contains(where: { !$0.isNumber }) else { return nil }
        var index = authorityEnd
        var first: Substring.Index?
        while index < url.endIndex {
            if url[index] == "@", index > url.startIndex, url[url.index(before: index)] != "/" {
                first = index
                break
            }
            index = url.index(after: index)
        }
        guard let first else { return nil }
        let nextSlash = url[url.index(after: first)...].firstIndex(of: "/") ?? url.endIndex
        return url[first..<nextSlash].lastIndex(of: "@")
    }

    // MARK: helpers

    /// `text` with each match of `pattern` replaced by `replacement(match)`, or left as it is when that's nil.
    private static func replacing(_ pattern: NSRegularExpression, in text: String,
                                  _ replacement: (NSTextCheckingResult, String) -> String?) -> String {
        var result = ""
        var copied = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let new = replacement(match, text) else { continue }
            result += text[copied..<range.lowerBound] + new
            copied = range.upperBound
        }
        result += text[copied...]
        return result
    }
}
