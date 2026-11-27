import Foundation
import Testing
@testable import BrewxPortCore

@Suite struct PackageNameRulesTests {
    static let languages = EngineID.allCases.filter(\.isLanguage)

    static func refuses(_ name: String, _ engine: EngineID) -> Bool {
        do {
            try PackageNameRules.validate(name, for: engine)
            return false
        } catch let error as EngineError {
            return error.engine == engine && !error.message.isEmpty
        } catch {
            return false
        }
    }

    /// Specs a typo or a pasted command could turn into "install and run this code". Refused by every engine.
    static let dangerous = [
        "https://example.com/tool.tgz", "http://example.com/tool", "github:someone/tool", "gitlab:someone/tool",
        "git+https://github.com/someone/tool.git", "git+ssh://git@github.com/someone/tool.git",
        "git://github.com/someone/tool", "file:../tool", "../tool", "./tool", ".", "..", "/opt/tool", "~/tool",
        "~tool", "-e", "--force", "--global", "-g", "", " ", "tool name", "tool\nname", "tool\tname", "tool;rm",
        "$(touch x)", "`id`", "tool|sh", "C:tool", "tool\u{0}", "tööl", ".hidden",
    ]

    @Test func rejectsNonRegistrySpecs() {
        for engine in EngineID.allCases {
            for spec in Self.dangerous {
                #expect(Self.refuses(spec, engine), "\(engine): \(spec.debugDescription)")
            }
        }
        // Version and extras specifiers belong to BrewxPort's own arguments, never to the name.
        for engine in Self.languages {
            for spec in ["tool@1.0.0", "tool@latest", "tool==1.0", "tool>=1", "tool[extra]", "tool#main",
                         "someone/tool/extra", "https://github.com/someone/tool"] {
                #expect(Self.refuses(spec, engine), "\(engine): \(spec)")
            }
        }
        // owner/repo is a GitHub shorthand everywhere but Mint, where it's the only form.
        for engine in Self.languages where engine != .mint {
            #expect(Self.refuses("someone/tool", engine), "\(engine)")
        }
    }

    @Test func rejectsNamesTheToolsReadAsLocalFiles() {
        for engine in [EngineID.npm, .bun] {
            for name in ["tool.tgz", "tool.tar.gz", "tool.tar", "Tool.TGZ"] {
                #expect(Self.refuses(name, engine), "\(engine): \(name)")
            }
        }
        for engine in [EngineID.pipx, .uv] {
            for name in ["tool.whl", "tool.zip", "tool.tar.gz", "tool.tgz", "tool.tar", "tool.tar.bz2", "tool.tbz",
                         "tool.tar.xz", "tool.txz", "tool.tlz", "tool.tar.lz", "tool.tar.lzma", "Tool.WHL"] {
                #expect(Self.refuses(name, engine), "\(engine): \(name)")
            }
        }
        #expect(Self.refuses("tool.gem", .gem))
        #expect(Self.refuses("tool.GEM", .gem))
    }

    @Test func acceptsRegistryNames() throws {
        let valid: [EngineID: [String]] = [
            .npm: ["typescript", "@angular/cli", "npm-check-updates", "lodash.merge", "JSONStream", "@types/node",
                   "a", "x~y", String(repeating: "a", count: 214)],
            .bun: ["typescript", "@biomejs/biome", "prettier"],
            .pipx: ["black", "pycowsay", "Django", "zope.interface", "jupyter_core", "a", "ruff-lsp", "pip-tools"],
            .uv: ["ruff", "httpie", "Pygments", "x"],
            .cargo: ["ripgrep", "cargo-edit", "fd-find", "tree_sitter", "x", String(repeating: "a", count: 64)],
            .gem: ["rubocop", "bundler", "net-http", "ruby_parser", "rails", "3scale-api", "a.b"],
            .mint: ["realm/SwiftLint", "yonaskolb/XcodeGen", "nicklockwood/SwiftFormat", "apple/swift-format",
                    "some-one/tool.kit", "x/_y"],
            .homebrew: ["wget", "node@22", "gtk+3", "homebrew/cask/firefox", "someone/tap/tool", "python@3.13"],
            .nanobrew: ["ripgrep", "node@22"],
            .macports: ["py313-black", "p5.34-xml-parser", "ripgrep"],
            .mas: ["497799835"],
        ]
        #expect(Set(valid.keys) == Set(EngineID.allCases))
        for (engine, names) in valid {
            for name in names {
                #expect(throws: Never.self, "\(engine): \(name)") { try PackageNameRules.validate(name, for: engine) }
            }
        }
    }

    @Test func enforcesEachEcosystemsOwnShape() {
        let invalid: [EngineID: [String]] = [
            .npm: ["@scope", "@/tool", "@scope/", "_tool", "tool/", String(repeating: "a", count: 215)],
            .pipx: ["-tool", "tool-", "_tool", "tool.", "tool!"],
            .uv: ["tool_", ".tool"],
            .cargo: ["1tool", "_tool", "tool.rs", "tool+x", String(repeating: "a", count: 65)],
            .gem: ["123", "_tool", "tool+x", "tool/x"],
            .mint: ["SwiftLint", "-owner/repo", "owner/-repo", "owner/.repo", "owner/..", "../repo", "own_er/repo",
                    "owner//repo", "owner/repo@0.1", "owner/repo.git@main"],
        ]
        for (engine, names) in invalid {
            for name in names {
                #expect(Self.refuses(name, engine), "\(engine): \(name)")
            }
        }
    }

    /// Mint turns a reference containing "github.com" into `https://<reference>.git`, and one whose first part has a
    /// dot into `https://<reference>`, so either would clone from whatever host the name starts with.
    @Test func mintRefusesNamesThatPointAtAnotherHost() {
        for name in ["evil/github.com", "x/my-github.com-tools", "x/GitHub.COM", "evil/github.com.git",
                     "github.com/x", "evil.example/repo", "owner/../x", "owner/repo:1",
                     "git" + "@github.com:x/y", "owner/.", "owner/...", "owner/.hidden", "owner/a b", "owner/a@b",
                     "owner/a:b", "owner/a/b", "https://github.com/x/y"] {
            #expect(Self.refuses(name, .mint), "\(name)")
        }
        for name in ["realm/SwiftLint", "apple/swift-format", "x/github-tools", "x/my.github.tools", "x/a.b_c-d"] {
            #expect(throws: Never.self, "\(name)") { try PackageNameRules.validate(name, for: .mint) }
        }
    }

    @Test func refusalNamesTheEngineAndShowsTheNameSafely() throws {
        let error = try #require(throws: EngineError.self) {
            try PackageNameRules.validate("github:someone/tool", for: .npm)
        }
        #expect(error.engine == .npm)
        #expect(error.message.contains("github:someone/tool"))
        #expect(error.message.contains("npm"))
        // Control characters are escaped, and a long spec is cut short.
        let long = try #require(throws: EngineError.self) {
            try PackageNameRules.validate("tool\n" + String(repeating: "x", count: 500), for: .cargo)
        }
        #expect(!long.message.contains("\n"))
        #expect(long.message.count < 300)
        let mint = try #require(throws: EngineError.self) { try PackageNameRules.validate("SwiftLint", for: .mint) }
        #expect(mint.message.contains("owner/repo"))
    }

    @Test func pythonNamesNormalizeLikePEP503() {
        #expect(PackageNameRules.normalizedPythonName("Django") == "django")
        #expect(PackageNameRules.normalizedPythonName("zope.interface") == "zope-interface")
        #expect(PackageNameRules.normalizedPythonName("jupyter_core") == "jupyter-core")
        #expect(PackageNameRules.normalizedPythonName("Foo._-Bar") == "foo-bar")
        #expect(PackageNameRules.normalizedPythonName("pip-tools") == "pip-tools")
    }
}
