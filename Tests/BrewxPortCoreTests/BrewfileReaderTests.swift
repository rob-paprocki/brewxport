import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/brewfile/\(name).Brewfile")
    return try String(contentsOf: url, encoding: .utf8)
}

/// The fixture's lines (1-based: `lines(text)[0]` is line 1), with no trailing empty piece.
private func lines(_ text: String) -> [String] {
    var parts = text.components(separatedBy: "\n")
    if parts.last == "" { parts.removeLast() }
    return parts
}

private func joined(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

private func formula(_ name: String) -> PackageRef { PackageRef(engine: .homebrew, kind: .formula, name: name) }
private func cask(_ name: String) -> PackageRef { PackageRef(engine: .homebrew, kind: .cask, name: name) }
private func tap(_ name: String) -> PackageRef { PackageRef(engine: .homebrew, kind: .tap, name: name) }

private let basicRefs = [
    tap("felixkratz/formulae"), formula("jq"), formula("mas"), formula("felixkratz/formulae/borders"),
    cask("rectangle"), cask("visual-studio-code"),
]

private func holdsInvariant(_ doc: BrewfileDocument) -> Bool {
    doc.entries.count + doc.unhandled.count + doc.ignoredCount == doc.lineCount
}

private func reason(_ doc: BrewfileDocument, line: Int) -> String? {
    doc.unhandled.first { $0.line == line }?.reason
}

@Suite struct BrewfileReaderTests {
    @Test func basicDumpCounts() throws {
        let doc = BrewfileReader.read(try fixture("dump-basic"))
        #expect(doc.lineCount == 10)
        #expect(doc.entries.map(\.ref) == basicRefs)
        #expect(doc.entries.map(\.line) == [1, 2, 3, 4, 5, 6])
        #expect(doc.unhandled.map(\.line) == [7, 8, 9, 10])
        #expect(doc.ignoredCount == 0)
        for line in 7...10 { #expect(reason(doc, line: line) == "BrewxPort doesn't handle `vscode` lines") }
        #expect(holdsInvariant(doc))
    }

    @Test func describeDumpMatchesBasic() throws {
        let doc = BrewfileReader.read(try fixture("dump-describe"))
        #expect(doc.lineCount == 15)
        #expect(doc.entries.map(\.ref) == basicRefs)
        #expect(doc.unhandled.count == 4)
        #expect(doc.unhandled.map(\.line) == [12, 13, 14, 15])
        #expect(doc.ignoredCount == 5)
        #expect(holdsInvariant(doc))
    }

    @Test func vscodeLinesUnhandled() throws {
        let doc = BrewfileReader.read(try fixture("dump-vscode"))
        #expect(doc.entries.isEmpty)
        #expect(doc.unhandled.map(\.line) == [1, 2, 3, 4])
        #expect(doc.unhandled.allSatisfy { $0.reason.contains("`vscode`") })
        #expect(holdsInvariant(doc))
    }

    @Test func readmeEveryCodeLineUnhandled() throws {
        let text = try fixture("homebrew-bundle-readme")
        let doc = BrewfileReader.read(text)
        let codeLines = lines(text).filter {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        // Lines 26-27 (`brew`/`cask "user/repository/…", trusted: true`) are the only lines BrewxPort takes.
        #expect(doc.entries.map(\.line) == [26, 27])
        #expect(doc.entries.map(\.ref) == [formula("user/repository/formula"), cask("user/repository/cask")])
        #expect(doc.unhandled.count == codeLines.count - 2)
        #expect(doc.ignoredCount == doc.lineCount - codeLines.count)
        #expect(reason(doc, line: 25) == "has options BrewxPort doesn't apply: `trusted`")
        #expect(reason(doc, line: 2) == "tap from a custom URL")
        for line in [17, 18, 30, 31, 32, 33, 34] {
            #expect(reason(doc, line: line) == "statement continues on the next line")
        }
        for line in [39, 40, 58] { #expect(reason(doc, line: line) == "conditional line") }
        #expect(reason(doc, line: 6) == "BrewxPort doesn't handle `cask_args` lines")
        #expect(reason(doc, line: 65) == "BrewxPort doesn't handle `ENV` lines")
        #expect(reason(doc, line: 10) == "has options BrewxPort doesn't apply: `link`, `args`, `restart_service`")
        #expect(holdsInvariant(doc))
    }

    @Test func typesBlockEntries() throws {
        let doc = BrewfileReader.read(try fixture("homebrew-bundle-types"))
        #expect(doc.entries.map(\.ref) == [
            tap("apple/apple"), formula("apple/apple/game-porting-toolkit"), cask("firefox"),
            PackageRef(engine: .mas, kind: .app, name: "1519867270"),
        ])
        #expect(reason(doc, line: 3) == "has options BrewxPort doesn't apply: `restart_service`")
        let words = [6: "winget", 7: "winget", 8: "vscode", 9: "go", 10: "cargo", 11: "cargo", 12: "uv", 13: "uv",
                     14: "krew", 15: "flatpak", 16: "flatpak", 17: "flatpak"]
        #expect(doc.unhandled.map(\.line) == [3] + words.keys.sorted())
        for (line, word) in words { #expect(reason(doc, line: line) == "BrewxPort doesn't handle `\(word)` lines") }
        #expect(doc.ignoredCount == 0)
        #expect(holdsInvariant(doc))
    }

    @Test func masLineKeepsIdAndName() throws {
        let doc = BrewfileReader.read(try fixture("homebrew-bundle-types"))
        let mas = try #require(doc.entries.first { $0.line == 5 })
        #expect(mas.ref == PackageRef(engine: .mas, kind: .app, name: "1519867270"))
        #expect(mas.displayName == "Refined GitHub")
    }

    @Test func blockBodyUnhandledBlankIgnored() throws {
        // DERIVED from dump-basic: lines 2-3 wrapped in `if OS.mac?` … `end`, with a blank and a comment line inside.
        var l = lines(try fixture("dump-basic"))
        l.replaceSubrange(1...2, with: ["if OS.mac?", l[1], "", "  # inside", l[2], "end"])
        let doc = BrewfileReader.read(joined(l))
        #expect(doc.lineCount == 14)
        #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae"), formula("felixkratz/formulae/borders"), cask("rectangle"), cask("visual-studio-code")])
        for line in [2, 3, 6, 7] { #expect(reason(doc, line: line) == "inside Ruby logic") }
        #expect(doc.ignoredCount == 2)
        #expect(holdsInvariant(doc))
    }

    @Test func singleQuotesAndParensAccepted() throws {
        // DERIVED from dump-basic: line 2 rewritten as `brew 'jq'`, then as `brew("jq")`.
        for rewrite in ["brew 'jq'", #"brew("jq")"#, #"brew("jq") # trailing comment"#] {
            var l = lines(try fixture("dump-basic"))
            l[1] = rewrite
            let doc = BrewfileReader.read(joined(l))
            #expect(doc.entries.map(\.ref) == basicRefs, "\(rewrite)")
            #expect(doc.entries.first { $0.line == 2 }?.displayName == "jq")
        }
    }

    @Test func crlfAndBomParseLikeLF() throws {
        // DERIVED from dump-basic: CRLF line endings, a leading BOM, and both.
        let text = try fixture("dump-basic")
        let plain = BrewfileReader.read(text)
        let crlf = text.replacingOccurrences(of: "\n", with: "\r\n")
        for variant in [crlf, "\u{FEFF}" + text, "\u{FEFF}" + crlf] {
            #expect(BrewfileReader.read(variant) == plain)
        }
    }

    @Test func badNamesUnhandled() throws {
        // DERIVED from dump-basic: lines rewritten to hostile names.
        var l = lines(try fixture("dump-basic"))
        l[1] = #"brew "../x""#
        l[2] = #"brew "--force""#
        l[4] = #"cask "-x""#
        l[0] = #"tap "../x""#
        let doc = BrewfileReader.read(joined(l))
        #expect(doc.entries.map(\.ref) == [formula("felixkratz/formulae/borders"), cask("visual-studio-code")])
        #expect(reason(doc, line: 1) == "“../x” isn't a valid Homebrew tap name")
        #expect(reason(doc, line: 2) == "“../x” isn't a valid Homebrew formula name")
        #expect(reason(doc, line: 3) == "“--force” isn't a valid Homebrew formula name")
        #expect(reason(doc, line: 5) == "“-x” isn't a valid Homebrew cask name")
        #expect(holdsInvariant(doc))
    }

    @Test func builtInTapUnhandled() throws {
        // DERIVED from dump-basic: line 1 rewritten to Homebrew's own taps, with and without a URL.
        for rewrite in [#"tap "homebrew/core""#, #"tap "Homebrew/cask""#,
                        #"tap "homebrew/core", "https://github.com/Homebrew/homebrew-core""#] {
            var l = lines(try fixture("dump-basic"))
            l[0] = rewrite
            let doc = BrewfileReader.read(joined(l))
            #expect(reason(doc, line: 1) == "Homebrew's built-in tap, nothing to add", "\(rewrite)")
        }
    }

    @Test func tapDefaultURLVariants() throws {
        // DERIVED from dump-basic: line 1's URL with `.git`, and with other hosts or paths.
        let accepted = ["https://github.com/FelixKratz/homebrew-formulae.git", "HTTPS://GITHUB.COM/felixkratz/homebrew-formulae"]
        let custom = ["https://github.com/FelixKratz/homebrew-formulae/", "https://github.com/other/homebrew-formulae",
                      "http://github.com/FelixKratz/homebrew-formulae", "https://example.com/FelixKratz/homebrew-formulae"]
        for url in accepted + custom {
            var l = lines(try fixture("dump-basic"))
            l[0] = #"tap "felixkratz/formulae", ""# + url + #"""#
            let doc = BrewfileReader.read(joined(l))
            if accepted.contains(url) {
                #expect(doc.entries.first?.ref == tap("felixkratz/formulae"), "\(url)")
            } else {
                #expect(reason(doc, line: 1) == "tap from a custom URL", "\(url)")
            }
        }
    }

    @Test func trustedTrueOnTapFormulaAccepted() {
        let doc = BrewfileReader.read(joined([
            #"brew "felixkratz/formulae/borders", trusted: true"#,
            #"cask("user/repository/cask", trusted: true) # note"#,
            #"brew "homebrew/core/jq""#,
        ]))
        #expect(doc.entries.map(\.ref) == [formula("felixkratz/formulae/borders"), cask("user/repository/cask"),
                                          formula("homebrew/core/jq")])
        #expect(doc.unhandled.isEmpty)
        #expect(holdsInvariant(doc))
    }

    @Test func trustedOnUnqualifiedNameUnhandled() {
        let doc = BrewfileReader.read(joined([
            #"brew "jq", trusted: true"#, #"cask "rectangle", trusted: true"#,
            #"brew "homebrew/core/jq", trusted: true"#, #"cask "Homebrew/Cask/rectangle", trusted: true"#,
            #"tap "user/repository", trusted: true"#, #"mas "App", id: 123, trusted: true"#,
        ]))
        #expect(doc.entries.isEmpty)
        #expect(doc.unhandled.map(\.line) == [1, 2, 3, 4, 5, 6])
        #expect(reason(doc, line: 1) == "has options BrewxPort doesn't apply: `trusted`")
        #expect(holdsInvariant(doc))
    }

    @Test func trustedFalseUnhandled() {
        for value in ["false", "1", "\"true\"", "{ formula: \"borders\" }"] {
            let doc = BrewfileReader.read(joined([#"brew "user/repo/borders", trusted: "# + value]))
            #expect(doc.entries.isEmpty, "\(value)")
            #expect(reason(doc, line: 1) == "has options BrewxPort doesn't apply: `trusted`", "\(value)")
        }
    }

    @Test func trustedWithOtherKeyUnhandled() {
        let doc = BrewfileReader.read(joined([
            #"brew "user/repo/x", trusted: true, link: false"#,
            #"brew "user/repo/y", args: ["HEAD"], trusted: true"#,
            #"brew "user/repo/z", trusted: true, trusted: true"#,
        ]))
        #expect(doc.entries.isEmpty)
        #expect(reason(doc, line: 1) == "has options BrewxPort doesn't apply: `trusted`, `link`")
        #expect(reason(doc, line: 2) == "has options BrewxPort doesn't apply: `args`, `trusted`")
        #expect(reason(doc, line: 3) == "has the option `trusted` twice")
        #expect(holdsInvariant(doc))
    }

    @Test func oddShapesUnhandled() throws {
        // DERIVED from dump-basic: line 2 rewritten to shapes the reader must not take as `jq`.
        let rewrites = [
            #"brew "jq"; brew "x""#, #"brew "jq", "x""#, #"brew "j\q""#, #"brew "jq" + "x""#, #"brew :jq"#,
            #"brew "jq", :args => ["x"]"#, "brew", #"mas "App""#, #"brew "jq"#, "  end",
        ]
        for rewrite in rewrites {
            var l = lines(try fixture("dump-basic"))
            l[1] = rewrite
            let doc = BrewfileReader.read(joined(l))
            #expect(!doc.entries.contains { $0.line == 2 }, "\(rewrite)")
            #expect(!doc.entries.contains { $0.ref.name.contains("jq") }, "\(rewrite)")
            #expect(holdsInvariant(doc), "\(rewrite)")
        }
    }

    @Test func commentBlockLinesUnhandled() throws {
        // DERIVED from dump-basic: lines 2-3 inside `=begin`/`=end`; a comment block doesn't stop later entries.
        var l = lines(try fixture("dump-basic"))
        l.replaceSubrange(1...2, with: ["=begin", l[1], l[2], "=end"])
        let doc = BrewfileReader.read(joined(l))
        #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae"), formula("felixkratz/formulae/borders"), cask("rectangle"), cask("visual-studio-code")])
        for line in 2...5 { #expect(reason(doc, line: line) == "inside a =begin/=end comment") }
        #expect(holdsInvariant(doc))
    }

    /// A heredoc's extent: its body lines read "statement continues", and every entry after it is unhandled
    /// because nothing after a heredoc is trusted.
    private func expectHeredoc(_ l: [String], body: ClosedRange<Int>, firstAfter: Int,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        let doc = BrewfileReader.read(joined(l))
        #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae")], sourceLocation: sourceLocation)
        for line in body {
            #expect(reason(doc, line: line) == "statement continues on the next line", sourceLocation: sourceLocation)
        }
        #expect(reason(doc, line: firstAfter) == "after Ruby code BrewxPort can't follow (line 2)",
                sourceLocation: sourceLocation)
        #expect(holdsInvariant(doc), sourceLocation: sourceLocation)
    }

    @Test func heredocBodiesUnhandled() throws {
        // DERIVED from dump-basic: lines 2-3 inside a heredoc on a followable line.
        for (open, close) in [("vscode <<~EOS", "  EOS"), ("vscode <<-'EOS'", "EOS")] {
            var l = lines(try fixture("dump-basic"))
            l.replaceSubrange(1...2, with: [open, l[1], l[2], close])
            expectHeredoc(l, body: 2...5, firstAfter: 7)
        }
    }

    @Test func indentedHeredocTerminatorWithTrailingSpaceDoesNotEnd() throws {
        // DERIVED from dump-basic: `EOS ` and `  EOS\t` aren't terminators; line 2 sits after them.
        for (open, fake) in [("vscode <<~EOS", "EOS "), ("vscode <<-EOS", "  EOS\t")] {
            var l = lines(try fixture("dump-basic"))
            l.replaceSubrange(1...1, with: [open, fake, l[1], "EOS"])
            expectHeredoc(l, body: 2...5, firstAfter: 6)
        }
    }

    @Test func plainHeredocNeedsColumnZeroTerminator() throws {
        // DERIVED from dump-basic: `<<EOS` with an indented `EOS` that doesn't end it; the real terminator follows.
        var l = lines(try fixture("dump-basic"))
        l.replaceSubrange(1...1, with: ["vscode <<EOS", "  EOS", l[1], "EOS"])
        expectHeredoc(l, body: 2...5, firstAfter: 6)
    }

    @Test func secondHeredocOnALineSkipped() throws {
        // DERIVED from dump-basic: `vscode [<<A, <<B]` with `brew "jq"` inside the second body.
        var l = lines(try fixture("dump-basic"))
        l.replaceSubrange(1...1, with: ["vscode [<<~A, <<~B]", "a", "A", l[1], "B"])
        expectHeredoc(l, body: 2...6, firstAfter: 7)
    }

    @Test func codeInConditionsAndValuesStopsTrust() throws {
        // DERIVED from dump-basic: code hidden in a condition, an option value, or a one-line `if … then … end`
        // is put before line 2. Everything the reader would accept after it is unhandled.
        let redefine = "define_singleton_method(:brew) { |n| cask n }"
        let preludes: [[String]] = [
            ["if \(redefine)", "end"],
            ["vscode \"x\" unless \(redefine)"],
            ["brew \"x\", args: [\(redefine)]"],
            ["if true then \(redefine) end"],
            ["brew \"x\" if (raise \"y\")"],
            ["if raise(\"stop\")", "end"],
            ["if false", "elsif exit", "end"],
            ["case raise(\"x\")", "end"],
            ["if instance_eval(\"def brew(*) end\")", "end"],
            ["ENV[\"X\"].replace(\"y\") && raise"],
            ["vscode \"x\" if system \"true\""],
            ["vscode \"x\" if Kernel::exit"],
        ]
        for prelude in preludes {
            var l = lines(try fixture("dump-basic"))
            l.insert(contentsOf: prelude, at: 1)
            let doc = BrewfileReader.read(joined(l))
            #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae")], "\(prelude)")
            #expect(holdsInvariant(doc), "\(prelude)")
        }
    }

    @Test func shorthandKeysStopTrust() throws {
        // DERIVED from dump-basic: Ruby 3.1 shorthand (`{raise:}`, `f(exit:)`) is a call to `raise`/`exit`, not a
        // hash key, so a key with no value is code BrewxPort can't follow. Put before line 2.
        let preludes: [[String]] = [
            ["vscode \"x\", args: {raise:}"],
            ["vscode \"x\", args: { raise: }"],
            ["vscode \"x\", args: {a: 1, exit:, b: 2}"],
            ["vscode(\"x\", exit:)"],
            ["vscode \"x\", args: [exit:]"],
            ["vscode \"x\", args: {exit:", "}"],
            ["vscode \"x\", args: {exit: # stop", "}"],
            ["if {raise:}", "end"],
        ]
        for prelude in preludes {
            var l = lines(try fixture("dump-basic"))
            l.insert(contentsOf: prelude, at: 1)
            let doc = BrewfileReader.read(joined(l))
            #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae")], "\(prelude)")
            #expect(holdsInvariant(doc), "\(prelude)")
            let after = doc.unhandled.first { $0.text == #"brew "mas""# }
            #expect(after?.reason.hasPrefix("after Ruby code BrewxPort can't follow") == true, "\(prelude)")
        }
    }

    @Test func keysWithValuesAndScopesStillFollowed() throws {
        // DERIVED from dump-basic: a key with a value, `::` and a symbol value don't stop later entries.
        let preludes: [[String]] = [
            ["vscode \"x\", args: {a: 1}"],
            ["vscode \"x\", args: {a: true}, b: nil"],
            ["vscode \"x\" if Hardware::CPU.arm?"],
            ["vscode \"x\", a: :b"],
        ]
        for prelude in preludes {
            var l = lines(try fixture("dump-basic"))
            l.insert(contentsOf: prelude, at: 1)
            let doc = BrewfileReader.read(joined(l))
            #expect(doc.entries.map(\.ref) == basicRefs, "\(prelude)")
        }
    }

    @Test func platformConditionsStillFollowed() throws {
        // DERIVED from dump-basic: the condition words real Brewfiles use don't stop later entries.
        let preludes: [[String]] = [
            ["vscode \"x\" if OS.mac? && Hardware::CPU.arm?"],
            ["if OS.linux? or not File.exist?(\"/x\")", "end"],
            ["unless MacOS.version", "end"],
        ]
        for prelude in preludes {
            var l = lines(try fixture("dump-basic"))
            l.insert(contentsOf: prelude, at: 1)
            let doc = BrewfileReader.read(joined(l))
            let followed = !prelude[0].contains("version")
            #expect(doc.entries.map(\.ref) == (followed ? basicRefs : [tap("felixkratz/formulae")]), "\(prelude)")
        }
    }

    @Test func entriesAfterUnfollowableRubyUnhandled() throws {
        // DERIVED from dump-basic: Ruby that may raise, redefine `brew`, loop or hide code is put before line 2.
        // Everything the reader would accept after it is unhandled, naming the line it lost track at.
        let preludes: [[String]] = [
            ["x = %q|"], ["x = /"], ["__END__"], ["false &&"], ["true or"], ["raise \"x\""], ["alias brew cask"],
            ["def brew(n); cask(n); end"], ["x = <<~EOS"], ["if false", "a = %w[end end]"], ["vscode `ls`"],
            ["vscode ?a"], ["vscode \"#{1}\""], ["loop do", "end"], ["tap \"a/b\" while false"], ["[1].each { }"],
        ]
        for prelude in preludes {
            var l = lines(try fixture("dump-basic"))
            l.insert(contentsOf: prelude, at: 1)
            let doc = BrewfileReader.read(joined(l))
            #expect(doc.entries.map(\.ref) == [tap("felixkratz/formulae")], "\(prelude)")
            #expect(holdsInvariant(doc), "\(prelude)")
            // `__END__` and an unterminated heredoc take every later line, so they have their own reasons.
            guard prelude != ["__END__"], prelude != ["x = <<~EOS"] else { continue }
            let lostLine = prelude.first == "if false" ? 3 : 2 // `if` itself can be followed
            let after = doc.unhandled.first { $0.text == #"brew "mas""# }
            #expect(after?.reason == "after Ruby code BrewxPort can't follow (line \(lostLine))", "\(prelude)")
        }
    }

    @Test func leadingDotJoinsPreviousLine() throws {
        // DERIVED from dump-basic: line 2 followed by `  .itself if false`, with a comment between.
        var l = lines(try fixture("dump-basic"))
        l.insert(contentsOf: ["  # chained", "  .itself if false"], at: 2)
        let doc = BrewfileReader.read(joined(l))
        #expect(!doc.entries.contains { $0.ref == formula("jq") })
        #expect(reason(doc, line: 2) == "statement continues on the next line")
        #expect(doc.ignoredCount == 1)
        #expect(holdsInvariant(doc))
    }

    @Test func masOctalAndRepeatedKeysUnhandled() throws {
        // DERIVED from homebrew-bundle-types line 5: id with a leading zero, and `id:` given twice.
        var l = lines(try fixture("homebrew-bundle-types"))
        l[4] = #"mas "Refined GitHub", id: 01519867270"#
        var doc = BrewfileReader.read(joined(l))
        #expect(reason(doc, line: 5) == "app id “01519867270” starts with 0, which Ruby reads as octal")
        l[4] = #"mas "Refined GitHub", id: 1, id: 1519867270"#
        doc = BrewfileReader.read(joined(l))
        #expect(reason(doc, line: 5) == "has the option `id` twice")
    }

    @Test func manyOptionsReasonIsShort() throws {
        // DERIVED from dump-basic: line 2 given 10,000 distinct options.
        var l = lines(try fixture("dump-basic"))
        l[1] += (0..<10_000).map { ", k\($0): 1" }.joined()
        let doc = BrewfileReader.read(joined(l))
        #expect(reason(doc, line: 2) == "has options BrewxPort doesn't apply: `k0`, `k1`, `k2`, `k3`, `k4`, …")
    }

    @Test func duplicateLineUnhandled() throws {
        // DERIVED from dump-basic: `brew "jq"` repeated at the end.
        var l = lines(try fixture("dump-basic"))
        l.append(l[1])
        let doc = BrewfileReader.read(joined(l))
        #expect(doc.entries.map(\.ref) == basicRefs)
        #expect(reason(doc, line: 11) == "listed twice (line 2)")
        #expect(holdsInvariant(doc))
    }

    @Test func controlCharactersEscapedInText() throws {
        // DERIVED from dump-basic: an escape sequence and a tab added to line 7.
        var l = lines(try fixture("dump-basic"))
        l[6] = "\t" + l[6] + "\u{1B}[2J"
        let doc = BrewfileReader.read(joined(l))
        let text = try #require(doc.unhandled.first { $0.line == 7 }?.text)
        #expect(text.hasPrefix("\t"))
        #expect(text.hasSuffix("\\u{1B}[2J"))
    }

    @Test func dataOverCapsRefused() throws {
        // DERIVED from dump-basic: padded past the byte cap, and repeated past the entry cap.
        let text = try fixture("dump-basic")
        let big = Data((text + String(repeating: "\n", count: BundleFile.maxFileBytes)).utf8)
        #expect(throws: BundleFileError.tooLarge) { try BrewfileReader.read(big) }
        let many = Data(String(repeating: "brew \"jq\"\n", count: BundleFile.maxEntries + 1).utf8)
        #expect(throws: BundleFileError.tooLarge) { try BrewfileReader.read(many) }
        // Lines that would all be heredoc body (unhandled), counted by the line cap, not as comments.
        let heredoc = Data(("vscode <<~EOS\n" + String(repeating: "#\n", count: BrewfileReader.maxLines)).utf8)
        #expect(throws: BundleFileError.tooLarge) { try BrewfileReader.read(heredoc) }
        let justUnder = Data(("vscode <<~EOS\n" + String(repeating: "#\n", count: BundleFile.maxEntries)).utf8)
        #expect(throws: BundleFileError.tooLarge) { try BrewfileReader.read(justUnder) }
        #expect(try BrewfileReader.read(Data(text.utf8)) == BrewfileReader.read(text))
        #expect(throws: BrewfileError.notText) { try BrewfileReader.read(Data([0x62, 0xFF, 0xFE, 0x0A])) }
    }

    @Test func invariantHoldsOnEveryFixture() throws {
        for name in ["dump-basic", "dump-describe", "dump-vscode", "homebrew-bundle-readme", "homebrew-bundle-types"] {
            let text = try fixture(name)
            let doc = BrewfileReader.read(text)
            #expect(doc.lineCount == lines(text).count, "\(name)")
            #expect(holdsInvariant(doc), "\(name)")
            let all = (doc.entries.map(\.line) + doc.unhandled.map(\.line))
            #expect(Set(all).count == all.count, "\(name)")
        }
    }
}
