import Foundation
import Testing
@testable import BrewxPortCore

@Suite struct ToolEnvironmentTests {
    static let base = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
    ]

    /// Exactly the plan's list, in its order.
    @Test func allowlistIsExactlyThePlansVariables() {
        #expect(ToolEnvironment.capturedVariables == [
            "NVM_DIR", "NPM_CONFIG_PREFIX", "npm_config_prefix", "PIPX_HOME", "PIPX_BIN_DIR", "UV_TOOL_DIR",
            "UV_TOOL_BIN_DIR", "CARGO_HOME", "CARGO_INSTALL_ROOT", "RUSTUP_HOME", "GEM_HOME", "GEM_PATH", "BUN_INSTALL",
            "BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN", "MINT_PATH", "MINT_LINK_PATH", "XDG_DATA_HOME", "XDG_BIN_HOME",
            "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
        ])
    }

    @Test func environmentPutsToolBinFirst() {
        let npm = URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm")
        let captured = ["NVM_DIR": "/Users/someone/.nvm", "NPM_TOKEN": "/not/allowed", "PATH": "/evil/bin",
                        "CARGO_HOME": "relative/.cargo"]
        let env = ToolEnvironment.make(for: .npm, executable: npm, captured: captured, base: Self.base)
        #expect(env["PATH"] == "/Users/someone/.nvm/versions/node/v22.11.0/bin:/opt/homebrew/bin:/usr/local/bin:"
                + "/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["NVM_DIR"] == "/Users/someone/.nvm")
        #expect(env["NO_COLOR"] == "1")
        // Only allowlisted, usable values are added; the base is kept as it was.
        #expect(env["NPM_TOKEN"] == nil)
        #expect(env["CARGO_HOME"] == nil)
        #expect(env.filter { $0.key != "PATH" && $0.key != "NO_COLOR" && $0.key != "NVM_DIR" }
                == Self.base.filter { $0.key != "PATH" })
    }

    @Test func toolFolderAlreadyOnPathMovesToTheFront() {
        let npm = URL(fileURLWithPath: "/usr/local/bin/npm")
        let env = ToolEnvironment.make(for: .npm, executable: npm, captured: [:], base: Self.base)
        #expect(env["PATH"] == "/usr/local/bin:/opt/homebrew/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        let bare = ToolEnvironment.make(for: .gem, executable: URL(fileURLWithPath: "/Users/someone/.rbenv/shims/gem"),
                                        captured: [:], base: [:])
        #expect(bare == ["PATH": "/Users/someone/.rbenv/shims:/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1"])
    }

    /// Every captured variable, with a usable value.
    static let everything = Dictionary(uniqueKeysWithValues: ToolEnvironment.capturedVariables.map {
        ($0, "/Users/someone/" + $0.lowercased())
    })

    @Test func environmentHasOnlyThatEnginesVariables() {
        let xdg = ["XDG_DATA_HOME", "XDG_BIN_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"]
        let expected: [EngineID: [String]] = [
            .npm: ["NVM_DIR", "NPM_CONFIG_PREFIX", "npm_config_prefix"],
            .pipx: ["PIPX_HOME", "PIPX_BIN_DIR"],
            .uv: ["UV_TOOL_DIR", "UV_TOOL_BIN_DIR"],
            .cargo: ["CARGO_HOME", "CARGO_INSTALL_ROOT", "RUSTUP_HOME"],
            .bun: ["BUN_INSTALL", "BUN_INSTALL_GLOBAL_DIR", "BUN_INSTALL_BIN"],
            .gem: ["GEM_HOME", "GEM_PATH"],
            .mint: ["MINT_PATH", "MINT_LINK_PATH"],
        ]
        for engine in EngineID.allCases {
            let own = engine.isLanguage ? (expected[engine] ?? []) + xdg : []
            #expect(ToolEnvironment.variables(for: engine) == own, "\(engine)")
            let env = ToolEnvironment.make(for: engine, executable: URL(fileURLWithPath: "/opt/homebrew/bin/tool"),
                                           captured: Self.everything, base: Self.base)
            let captured = Set(env.keys).intersection(ToolEnvironment.capturedVariables)
            #expect(captured == Set(own), "\(engine)")
            for name in own { #expect(env[name] == Self.everything[name], "\(engine) \(name)") }
        }
        // Each allowlisted variable belongs to exactly one manager, or to all of them (XDG).
        let owned = expected.values.flatMap { $0 }
        #expect(owned.count == Set(owned).count)
        #expect(Set(owned + xdg) == Set(ToolEnvironment.capturedVariables))
    }

    @Test func cargoEnvironmentDisablesRustupAutoInstall() {
        let cargo = URL(fileURLWithPath: "/Users/someone/.cargo/bin/cargo")
        let env = ToolEnvironment.make(for: .cargo, executable: cargo, captured: [:], base: Self.base)
        #expect(env["RUSTUP_AUTO_INSTALL"] == "0")
        // Even when the base says otherwise.
        let overridden = ToolEnvironment.make(for: .cargo, executable: cargo, captured: [:],
                                              base: ["RUSTUP_AUTO_INSTALL": "1"])
        #expect(overridden["RUSTUP_AUTO_INSTALL"] == "0")
        for engine in EngineID.allCases where engine != .cargo {
            let other = ToolEnvironment.make(for: engine, executable: cargo, captured: [:], base: Self.base)
            #expect(other["RUSTUP_AUTO_INSTALL"] == nil, "\(engine)")
        }
    }

    @Test func allowlistKeepsOnlyAbsolutePaths() {
        let kept = ToolEnvironment.allowlisted([
            "CARGO_HOME": "/Users/someone/.cargo",
            "GEM_PATH": "/Users/someone/.gem/ruby/4.0.0:/opt/homebrew/lib/ruby/gems/4.0.0",
            "NVM_DIR": "/Users/someone/node@22/.nvm",
        ])
        #expect(kept.count == 3)
        let dropped = ToolEnvironment.allowlisted([
            "CARGO_HOME": ".cargo", "RUSTUP_HOME": "~/.rustup", "BUN_INSTALL": "$HOME/.bun", "MINT_PATH": "",
            "NPM_CONFIG_PREFIX": "https://someone:secret@registry.example.com/",
            "npm_config_prefix": "//someone:secret@registry.example.com/", "XDG_DATA_HOME": "/Users/someone/a:b",
            "GEM_PATH": "/Users/someone/.gem:relative", "GEM_HOME": "/Users/some\none", "PIPX_HOME": "/Users/x\u{7}",
            "UV_TOOL_DIR": "/" + String(repeating: "a", count: 1024),
            "NPM_TOKEN": "/abc", "UV_INDEX_URL": "/simple", "PIP_INDEX_URL": "/simple", "HTTPS_PROXY": "/proxy",
            "PATH": "/bin", "cargo_home": "/Users/someone/.cargo",
        ])
        #expect(dropped.isEmpty)
        #expect(ToolEnvironment.allowlisted(["GEM_PATH": "/x/gems::/y/gems"]).isEmpty)
        #expect(ToolEnvironment.allowlisted(["GEM_PATH": "/a:"]).isEmpty)
        #expect(ToolEnvironment.allowlisted(["XDG_BIN_HOME": "/"]) == ["XDG_BIN_HOME": "/"])
    }
}
