import Foundation
import Testing
@testable import BrewxPortCore

@Suite struct LanguageToolTests {
    static let base = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone",
    ]
    static let tool = URL(fileURLWithPath: "/Users/someone/.cargo/bin/cargo")

    @Test func loginShellContextKeepsOnlyAllowlistedPaths() {
        let context = LoginShellContext(path: ["/opt/homebrew/bin"],
                                        environment: ["CARGO_HOME": "/Users/someone/.cargo", "NPM_TOKEN": "/secret",
                                                      "GEM_HOME": "relative"])
        #expect(context.environment == ["CARGO_HOME": "/Users/someone/.cargo"])
        #expect(LoginShellContext.none.path.isEmpty && LoginShellContext.none.environment.isEmpty)
    }

    /// Printed or dumped, neither a context nor a command shows a folder or a variable's value (they name the user's
    /// folders): only counts and variable names.
    @Test func printingNeverShowsFoldersOrValues() {
        let context = LoginShellContext(path: ["/Users/someone/.nvm/versions/node/v22.11.0/bin"],
                                        environment: ["NVM_DIR": "/Users/someone/.nvm"])
        let spec = CommandSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/cargo"),
                               arguments: ["install", "ripgrep"], needsRoot: false,
                               environment: ["CARGO_HOME": "/Users/someone/.cargo"], workingDirectory: "/Users/someone")
        for text in [String(describing: context), String(reflecting: context), String(describing: spec),
                     String(reflecting: spec)] {
            #expect(!text.contains("someone/."), "\(text)")
            #expect(!text.contains("/Users/someone\""), "\(text)")
        }
        var dumped = ""
        dump(context, to: &dumped)
        dump(spec, to: &dumped)
        #expect(!dumped.contains("someone/."))
        #expect(String(describing: context).contains("NVM_DIR"))
        #expect(String(describing: spec).contains("CARGO_HOME"))
        // A command without its own environment still prints its executable and arguments.
        let plain = CommandSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), arguments: ["upgrade", "jq"],
                                needsRoot: false)
        #expect(String(describing: plain).contains("upgrade"))
        #expect(plain.environment == nil && plain.workingDirectory == nil)
    }

    @Test func fixedToolRunsWithItsEnvironmentFromHome() async throws {
        let runner = FakeRunner([["--version"]: CommandResult(exitCode: 0, stdout: "cargo 1.91.0\n", stderr: "")])
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: Self.tool,
                                    captured: ["CARGO_HOME": "/Users/someone/.cargo", "NVM_DIR": "/Users/someone/.nvm"],
                                    settings: ["CARGO_TERM_COLOR": "never"], base: Self.base)
        #expect(language.executable == Self.tool)
        _ = try await language.run(["--version"])
        let options = try #require(runner.optionsCalls.first)
        let env = try #require(options.environment)
        #expect(env["PATH"] == "/Users/someone/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin")
        #expect(env["CARGO_HOME"] == "/Users/someone/.cargo")
        #expect(env["NVM_DIR"] == nil)
        #expect(env["CARGO_TERM_COLOR"] == "never")
        #expect(env["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(options.workingDirectory == "/Users/someone")
        let spec = try language.command(["install", "ripgrep"])
        #expect(spec == CommandSpec(executable: Self.tool, arguments: ["install", "ripgrep"], needsRoot: false,
                                    environment: env, workingDirectory: "/Users/someone"))
    }

    @Test func detectReportsVersionWithTheToolsEnvironment() async throws {
        let runner = FakeRunner([["--version"]: CommandResult(exitCode: 0, stdout: "cargo 1.91.0\n", stderr: "")])
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: Self.tool, base: Self.base)
        let status = await language.detect(["--version"]) {
            $0.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init)
        }
        #expect(status == .present(path: Self.tool, version: "1.91.0"))
        #expect(runner.optionsCalls.first?.environment?["PATH"]?.hasPrefix("/Users/someone/.cargo/bin:") == true)
        #expect(runner.optionsCalls.first?.workingDirectory == "/Users/someone")
        #expect(runner.optionsCalls.first?.timeout == BrewxPortTimeouts.engineQuery)
    }

    @Test func missingToolIsMissingAndRunsNothing() async {
        let runner = FakeRunner([:])
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: nil, base: Self.base)
        #expect(await language.detect(["--version"]) { $0 } == .missing)
        await #expect(throws: EngineError.self) { _ = try await language.run(["--version"]) }
        #expect(throws: EngineError.self) { _ = try language.command(["install", "x"]) }
        #expect(runner.calls.isEmpty)
    }

    /// cargo's `rustc`: the executable of that name in the tool's own folder (the same toolchain), with the tool's
    /// environment and folder. Only a plain file name is run.
    @Test func runsASiblingFromTheToolsFolder() async throws {
        let runner = FakeRunner([:], byExecutable: ["rustc": [["--version"]: CommandResult(
            exitCode: 0, stdout: "rustc 1.91.0\n", stderr: "")]])
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: Self.tool,
                                    captured: ["CARGO_HOME": "/Users/someone/.cargo"], base: Self.base)
        let result = try await language.run(sibling: "rustc", ["--version"])
        #expect(result.stdout == "rustc 1.91.0\n")
        #expect(runner.executableCalls == [URL(fileURLWithPath: "/Users/someone/.cargo/bin/rustc")])
        let options = try #require(runner.optionsCalls.first)
        #expect(options.environment?["PATH"]?.hasPrefix("/Users/someone/.cargo/bin:") == true)
        #expect(options.environment?["CARGO_HOME"] == "/Users/someone/.cargo")
        #expect(options.environment?["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(options.workingDirectory == "/Users/someone")
        for name in ["", ".", "..", "../rustc", "/usr/bin/rustc"] {
            await #expect(throws: EngineError.self, "\(name)") { _ = try await language.run(sibling: name, []) }
        }
        #expect(runner.calls.count == 1)
        let missing = LanguageTool(engine: .cargo, name: "cargo", runner: runner, executable: nil, base: Self.base)
        await #expect(throws: EngineError.self) { _ = try await missing.run(sibling: "rustc", ["--version"]) }
    }

    /// A command confirmed by a sibling, and what that sibling's output must show (`ConfirmationCheck`); without a
    /// check, the confirmation's exit code alone decides.
    @Test func commandCarriesItsConfirmationAndCheck() throws {
        let mint = URL(fileURLWithPath: "/opt/homebrew/bin/mint")
        let language = LanguageTool(engine: .mint, name: "mint", runner: FakeRunner([:]), executable: mint,
                                    base: Self.base)
        let check = ConfirmationCheck.mintAbsent(package: "JohnSundell/Ink",
                                                 metadata: "/Users/someone/.mint/metadata.json")
        let spec = try language.command(["uninstall", "https://github.com/JohnSundell/Ink.git"],
                                        confirmedBy: (sibling: "mint", arguments: ["list"]), checking: check)
        #expect(spec.confirmation == CommandConfirmation(executable: mint, arguments: ["list"], check: check))
        let plain = try language.command(["list"], confirmedBy: (sibling: "mint", arguments: ["list"]))
        #expect(plain.confirmation?.check == nil)
        #expect(try language.command(["list"]).confirmation == nil)
    }

    /// A variable as the tool's commands get it: the base's, the tool's own login-shell ones, the settings. None
    /// before the tool is found.
    @Test func variableIsTheCommandsValue() {
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: FakeRunner([:]), executable: Self.tool,
                                    captured: ["CARGO_HOME": "/Users/someone/rust", "NVM_DIR": "/Users/someone/.nvm"],
                                    settings: ["CARGO_TERM_COLOR": "never"], base: Self.base)
        #expect(language.variable("CARGO_HOME") == "/Users/someone/rust")
        #expect(language.variable("NVM_DIR") == nil)
        #expect(language.variable("CARGO_TERM_COLOR") == "never")
        #expect(language.variable("HOME") == "/Users/someone")
        #expect(language.variable("CARGO_INSTALL_ROOT") == nil)
        let missing = LanguageTool(engine: .cargo, name: "cargo", runner: FakeRunner([:]), executable: nil,
                                   captured: ["CARGO_HOME": "/Users/someone/rust"], base: Self.base)
        #expect(missing.variable("CARGO_HOME") == nil)
    }

    @Test func homeFallsBackWhenTheBaseHasNone() throws {
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: FakeRunner([:]), executable: Self.tool,
                                    base: ["PATH": "/usr/bin:/bin"])
        let spec = try language.command(["install", "x"])
        #expect(spec.workingDirectory == NSHomeDirectory())
    }

    @Test func decodesJSONOrSaysWhichToolItCouldntRead() throws {
        let language = LanguageTool(engine: .cargo, name: "cargo", runner: FakeRunner([:]), executable: Self.tool,
                                    base: Self.base)
        #expect(try language.decode([String: Int].self, from: #"{"a": 1}"#) == ["a": 1])
        do {
            _ = try language.decode([String: Int].self, from: "not json")
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .cargo)
            #expect(error.message.hasPrefix("Couldn't read cargo's JSON output"))
        }
        let failure = language.failure("cargo search failed", CommandResult(exitCode: 101, stdout: "", stderr: " boom \n"))
        #expect(failure == EngineError(engine: .cargo, message: "cargo search failed (exit 101): boom"))
    }

    /// A failure's stderr loses any URL credentials before it's cut to 300 characters, so a cut can't leave half a
    /// token. Not a capture.
    @Test func failureNeverShowsURLCredentials() {
        let language = LanguageTool(engine: .uv, name: "uv", runner: FakeRunner([:]), executable: Self.tool,
                                    base: Self.base)
        let url = "https://__token__:s3cretvalue@pypi.example.com/simple/"
        for stderr in ["error: no index at \(url)", String(repeating: "x", count: 280) + " " + url] {
            let failure = language.failure("uv tool list failed",
                                           CommandResult(exitCode: 2, stdout: "", stderr: stderr))
            #expect(!failure.message.contains("s3cret"), "\(stderr.count)")
            #expect(!failure.message.contains("__token__"), "\(stderr.count)")
        }
        let whole = language.failure("uv tool list failed",
                                     CommandResult(exitCode: 2, stdout: "", stderr: "error: no index at \(url)"))
        #expect(whole.message == "uv tool list failed (exit 2): error: no index at https://pypi.example.com/simple/")
    }
}
