import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/macports/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let port = URL(fileURLWithPath: "/opt/local/bin/port")
private func ok(_ out: String, err: String = "") -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: err) }
private func ref(_ name: String, engine: EngineID = .macports, kind: PackageKind = .port) -> PackageRef {
    PackageRef(engine: engine, kind: kind, name: name)
}

@Suite struct MacPortsEngineTests {
    private func engine(_ responses: [[String]: CommandResult] = [:]) -> (MacPortsEngine, FakeRunner) {
        let runner = FakeRunner(responses)
        return (MacPortsEngine(runner: runner, executable: port), runner)
    }

    @Test func detectsVersion() async throws {
        let (e, _) = engine([["version"]: ok(try fixture("version.txt"))])
        #expect(await e.detect() == .present(path: port, version: "2.12.7"))
    }

    @Test func detectMissingWithoutExecutable() async {
        let runner = FakeRunner([:])
        #expect(await MacPortsEngine(runner: runner, executable: nil).detect() == .missing)
        #expect(runner.calls.isEmpty)
    }

    @Test func detectUnusableOnFailureOrGarbage() async {
        let (failing, _) = engine([["version"]: CommandResult(exitCode: 1, stdout: "Version: 2.12.7", stderr: "")])
        #expect(isUnusable(await failing.detect(), at: port))
        let (garbage, _) = engine([["version"]: ok("hello\n")])
        #expect(isUnusable(await garbage.detect(), at: port))
    }

    @Test func parsesSearchLines() async throws {
        let (e, runner) = engine([["search", "--line", "ripgrep"]: ok(try fixture("search.txt"))])
        let found = try await e.search("ripgrep")
        #expect(runner.calls == [["search", "--line", "ripgrep"]])
        #expect(found.map(\.id.name) == ["ned", "repgrep", "ripgrep", "ripgrep-all"])
        let rg = try #require(found.first { $0.id.name == "ripgrep" })
        #expect(rg.latestVersion == "15.2.0")
        #expect(rg.summary == "fast command line search tool")
        #expect(rg.displayName == "ripgrep")
        #expect(rg.id == ref("ripgrep"))
        #expect(rg.installedVersion == nil)
    }

    @Test func parsesIntelSearch() async throws {
        let (e, _) = engine([["search", "--line", "figlet"]: ok(try fixture("x86_64/search.txt"))])
        let found = try await e.search("figlet")
        #expect(found.map(\.id.name) == ["figlet", "py-pyfiglet", "py310-pyfiglet", "py311-pyfiglet", "py312-pyfiglet", "py313-pyfiglet", "py314-pyfiglet", "toilet"])
        let fig = try #require(found.first { $0.id.name == "figlet" })
        #expect(fig.latestVersion == "2.2.5")
        #expect(fig.summary == "banner-like program prints strings as ASCII art")
        #expect(fig.installedVersion == nil)
    }

    @Test func parsesIntelInstalled() async throws {
        let (e, _) = engine([["-v", "-q", "installed", "active"]: ok(try fixture("x86_64/installed.txt"))])
        let pkgs = try await e.listInstalled()
        #expect(pkgs.map(\.id.name) == ["figlet"])
        #expect(pkgs.first?.installedVersion == "2.2.5_0")
        #expect(pkgs.allSatisfy { $0.id.engine == .macports && $0.id.kind == .port && $0.latestVersion == nil })
        // Captured on an Apple silicon VM whose MacPorts has `build_arch x86_64`.
        #expect(pkgs.first?.installedArchs == [.x86_64])
    }

    @Test func installedArchsFromVerboseList() async throws {
        // Captured on Apple silicon (brewxport-run1): noarch, single-arch and +universal ports.
        let (e, runner) = engine([["-v", "-q", "installed", "active"]: ok(try fixture("installed.txt"))])
        let pkgs = try await e.listInstalled()
        // The second call asks which ports were requested (InstalledOnRequestTests).
        #expect(runner.calls == [["-v", "-q", "installed", "active"], ["-q", "installed", "requested"]])
        let archs = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.id.name, $0.installedArchs) })
        #expect(archs["figlet"] == [.arm64])
        #expect(archs["nano"] == [.arm64, .x86_64])
        #expect(archs["bzip2"] == [.arm64, .x86_64])
        #expect(archs["autoconf"] == .some(nil))      // archs='noarch'
        #expect(archs["automake"] == .some(nil))
    }

    @Test func archsFieldEdgeCases() {
        // Not captures: the field's own edges, cut from the captured line shape.
        #expect(MacPortsEngine.archs(in: "  x @1_0 (active) platform='darwin 27'") == nil)
        #expect(MacPortsEngine.archs(in: "  x @1_0 (active) archs=''") == nil)
        #expect(MacPortsEngine.archs(in: "  x @1_0 (active) archs='ppc i386'") == nil)
        #expect(MacPortsEngine.archs(in: "  x @1_0 (active) archs='x86_64 ppc'") == [.x86_64])
        #expect(MacPortsEngine.archs(in: "  x @1_0 (active) archs='arm64") == nil)
    }

    @Test func noneOutdatedIntelIsEmpty() async throws {
        let (e, _) = engine([["-q", "outdated"]: ok(try fixture("x86_64/outdated-none.txt"))])
        #expect(try await e.listOutdated().isEmpty)
    }

    @Test func noMatchIsEmpty() async throws {
        let (e, _) = engine([["search", "--line", "zzzznotaport"]: ok("No match for zzzznotaport found\n")])
        #expect(try await e.search("zzzznotaport").isEmpty)
        let (quiet, _) = engine([["search", "--line", "zzzznotaport"]: ok("")])
        #expect(try await quiet.search("zzzznotaport").isEmpty)
        let exit1 = CommandResult(exitCode: 1, stdout: "No match for zzzznotaport found\n", stderr: "")
        let (e1, _) = engine([["search", "--line", "zzzznotaport"]: exit1])
        await #expect(throws: EngineError.self) { _ = try await e1.search("zzzznotaport") }
        let (junk, _) = engine([["search", "--line", "x"]: ok("something unexpected\n")])
        await #expect(throws: EngineError.self) { _ = try await junk.search("x") }
    }

    @Test func searchFailureThrowsWithStderr() async {
        let bad = CommandResult(exitCode: 2, stdout: "", stderr: "Error: port search failed: boom")
        let (e, _) = engine([["search", "--line", "x"]: bad])
        do {
            _ = try await e.search("x")
            Issue.record("expected throw")
        } catch let err as EngineError {
            #expect(err.engine == .macports)
            #expect(err.message.contains("boom"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func searchQueryStartingWithDashGetsSeparator() async throws {
        let (e, runner) = engine([["search", "--line", "--", "-x"]: ok("")])
        #expect(try await e.search("-x").isEmpty)
        #expect(runner.calls == [["search", "--line", "--", "-x"]])
        await #expect(throws: EngineError.self) { _ = try await e.search("  ") }
    }

    @Test func parsesInstalledActive() async throws {
        let (e, _) = engine([["-v", "-q", "installed", "active"]: ok(try fixture("installed.txt"))])
        let pkgs = try await e.listInstalled()
        #expect(pkgs.count == 18)
        let versions = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.id.name, $0.installedVersion) })
        #expect(versions["figlet"] == "2.2.5_0")
        #expect(versions["nano"] == "9.3_0")            // "@9.3_0+universal (active)"
        #expect(versions["bzip2"] == "1.0.8_1")
        #expect(pkgs.allSatisfy { $0.id.engine == .macports && $0.id.kind == .port && $0.latestVersion == nil })
        #expect(pkgs.allSatisfy { !$0.installedVersion!.contains("+") && !$0.installedVersion!.contains("@") })
    }

    @Test func emptyInstalledIsEmpty() async throws {
        let (e, _) = engine([["-v", "-q", "installed", "active"]: ok("")])
        #expect(try await e.listInstalled().isEmpty)
    }

    @Test func parsesOutdated() async throws {
        let (e, _) = engine([["-q", "outdated"]: ok(try fixture("outdated.txt"))])
        let pkgs = try await e.listOutdated()
        #expect(pkgs.count == 1)
        #expect(pkgs[0].id == ref("figlet"))
        #expect(pkgs[0].installedVersion == "2.2.5_0")
        #expect(pkgs[0].latestVersion == "2.2.6_0")
    }

    // TODO: no real capture of several outdated ports; this inline example follows the captured line shape.
    @Test func parsesSeveralOutdated() async throws {
        let text = "figlet                         2.2.5_0 < 2.2.6_0         \nzlib                           1.3.2_0 < 1.3.3_1         \n"
        let (e, _) = engine([["-q", "outdated"]: ok(text)])
        let pkgs = try await e.listOutdated()
        #expect(pkgs.map(\.id.name) == ["figlet", "zlib"])
        #expect(pkgs.map(\.latestVersion) == ["2.2.6_0", "1.3.3_1"])
    }

    // Not a capture: built from port's own format string (`format "%-30s %-24s %1s"` in action_outdated,
    // /opt/local/bin/port on the VM, MacPorts 2.12.7). No port on the VM was outdated with a reason suffix.
    @Test func outdatedReasonSuffixIgnored() async throws {
        let text = "openssl3                       3.4.0_0 < 3.4.0_0  (platform darwin 24 != darwin 25)  \n"
            + "foo                            1.0_0 < 2.0_0  (epoch 1 < 2)   \n"
            + "libcxx                         5.0_0 < 5.0_0  (C++ stdlib libstdc++ != libc++)  \n"
        let (e, _) = engine([["-q", "outdated"]: ok(text)])
        let pkgs = try await e.listOutdated()
        #expect(pkgs.map(\.id.name) == ["openssl3", "foo", "libcxx"])
        #expect(pkgs.map(\.installedVersion) == ["3.4.0_0", "1.0_0", "5.0_0"])
        #expect(pkgs.map(\.latestVersion) == ["3.4.0_0", "2.0_0", "5.0_0"])
    }

    @Test func outdatedRelationTokens() async throws {
        // Not a capture. `>` comes with a trailing `!` flag (verbose mode only); `!=` is accepted per the review.
        let text = "a  1_0 > 0.9_0 !\nb  1_0 != 2_0\nc  1_0 = 2_0\n"
        let (e, _) = engine([["-q", "outdated"]: ok(text)])
        #expect(try await e.listOutdated().map(\.id.name) == ["a", "b"])
    }

    @Test func noneOutdatedIsEmpty() async throws {
        let (e, _) = engine([["-q", "outdated"]: ok(try fixture("outdated-none.txt"))])
        #expect(try await e.listOutdated().isEmpty)
        // Inline, not a capture: unparseable output must throw rather than look empty.
        let (junk, _) = engine([["-q", "outdated"]: ok("No installed ports are outdated.\n"), ["-v", "-q", "installed", "active"]: ok("garbage\n")])
        await #expect(throws: EngineError.self) { _ = try await junk.listOutdated() }
        await #expect(throws: EngineError.self) { _ = try await junk.listInstalled() }
    }

    @Test func nonZeroExitThrows() async {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: "Error: registry broken")
        let (e, _) = engine([["-v", "-q", "installed", "active"]: bad, ["-q", "outdated"]: bad])
        await #expect(throws: EngineError.self) { _ = try await e.listInstalled() }
        await #expect(throws: EngineError.self) { _ = try await e.listOutdated() }
    }

    @Test func commandsUseNonInteractiveFirst() throws {
        let (e, _) = engine()
        #expect(try e.command(for: .install, [ref("figlet")], options: InstallOptions())
                == CommandSpec(executable: port, arguments: ["-N", "install", "figlet"], needsRoot: true))
        #expect(try e.command(for: .upgrade, [ref("a"), ref("b")], options: InstallOptions()).arguments == ["-N", "upgrade", "a", "b"])
        #expect(try e.command(for: .remove, [ref("a")], options: InstallOptions()).arguments == ["-N", "uninstall", "a"])
    }

    @Test func selfupdateRunsAsRootWithoutPortNames() throws {
        let (e, runner) = engine()
        #expect(try e.selfupdateCommand()
                == CommandSpec(executable: port, arguments: ["-N", "selfupdate"], needsRoot: true))
        // Built, never run here: the run sends it through the helper.
        #expect(runner.calls.isEmpty)
        let missing = MacPortsEngine(runner: FakeRunner([:]), executable: nil)
        #expect(throws: EngineError.self) { try missing.selfupdateCommand() }
    }

    @Test func variantsAreSeparateArgs() throws {
        let (e, _) = engine()
        let spec = try e.command(for: .install, [ref("gtk3")], options: InstallOptions(variants: ["+universal", "-x11"]))
        #expect(spec.arguments == ["-N", "install", "gtk3", "+universal", "-x11"])
    }

    @Test func extraArgsGoRightAfterVerb() throws {
        let (e, _) = engine()
        let spec = try e.command(for: .install, [ref("figlet")], options: InstallOptions(variants: ["+x11"], extraArgs: ["-s"]))
        #expect(spec.arguments == ["-N", "install", "-s", "figlet", "+x11"])
    }

    @Test func variantsNeedASinglePort() throws {
        let (e, _) = engine()
        #expect(throws: EngineError.self) {
            try e.command(for: .install, [ref("gtk3"), ref("cairo")], options: InstallOptions(variants: ["+x11"]))
        }
        // Several ports without variants are still one command.
        #expect(try e.command(for: .install, [ref("gtk3"), ref("cairo")], options: InstallOptions()).arguments == ["-N", "install", "gtk3", "cairo"])
    }

    @Test func validVariantsAccepted() throws {
        let (e, _) = engine()
        let v = ["+x11", "-x11", "+universal", "+mp_3"]
        #expect(try e.command(for: .install, [ref("a")], options: InstallOptions(variants: v)).arguments == ["-N", "install", "a"] + v)
    }

    @Test func rootAlways() throws {
        let (e, _) = engine()
        #expect(e.capabilities == [.sourceBuilds])
        #expect(e.id == .macports)
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(e.privilege(for: op, ref("figlet")) == .always)
            #expect(try e.command(for: op, [ref("figlet")], options: InstallOptions()).needsRoot)
        }
    }

    @Test func pseudoPortnamesAndSelectorsRejected() {
        let (e, _) = engine()
        for bad in ["installed", "ALL", "*", "name:foo", "depof:x", "not", "Outdated", "rleaves", "and", "OR", "a b", "a;b", "ripgrep*", "lib[a]", "é", ".hidden", "_x"] {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(bad)") { try e.command(for: op, [ref(bad)], options: InstallOptions()) }
            }
            #expect(throws: EngineError.self, "\(bad)") { try e.command(for: .install, [ref("ok"), ref(bad)], options: InstallOptions()) }
        }
    }

    @Test func realPortNamesAccepted() throws {
        let (e, _) = engine()
        let names = ["py312-numpy", "gtk3", "p5.36-foo", "libpng", "gtk+3", "Zip_1"]
        #expect(try e.command(for: .install, names.map { ref($0) }, options: InstallOptions()).arguments == ["-N", "install"] + names)
    }

    @Test func commandRejectsBadInput() {
        let (e, _) = engine()
        #expect(throws: EngineError.self) { try e.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a", engine: .homebrew)], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("-a")], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a")], options: InstallOptions(version: "1.0")) }
        for bad in ["universal", "+", "-", "+a b", "+a\tb", "", "+a\nb", "-f", "-x", "+x", "-y", "-u", "-s", "--force", "--version", "-N", "+a+b", "+a\u{0}b"] {
            #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a")], options: InstallOptions(variants: [bad])) }
        }
        #expect(throws: EngineError.self) { try e.command(for: .upgrade, [ref("a")], options: InstallOptions(variants: ["+x"])) }
        #expect(throws: EngineError.self) { try e.command(for: .remove, [ref("a")], options: InstallOptions(variants: ["+x"])) }
        #expect(throws: EngineError.self) { try MacPortsEngine(runner: FakeRunner([:]), executable: nil).command(for: .install, [ref("a")], options: InstallOptions()) }
    }
}

// MARK: info

private let infoArgs = ["info", "--name", "--description", "--homepage", "--version", "--variants", "--depends_lib", "--depends_run"]

@Suite struct MacPortsInfoTests {
    private func engine(_ name: String, _ output: String) -> (MacPortsEngine, FakeRunner) {
        let runner = FakeRunner([infoArgs + [name]: ok(output)])
        return (MacPortsEngine(runner: runner, executable: port), runner)
    }

    @Test func infoFromCapture() async throws {
        let (e, runner) = engine("ripgrep", try fixture("info-ripgrep.txt"))
        let d = try await e.info(ref("ripgrep"))
        #expect(runner.calls == [infoArgs + ["ripgrep"]])
        #expect(d.ref == ref("ripgrep"))
        #expect(d.summary == "fast command line search tool")
        #expect(d.homepage == URL(string: "https://github.com/BurntSushi/ripgrep"))
        #expect(d.latestVersion == "15.2.0")
        #expect(d.installedVersion == nil)
        #expect(d.variants == ["pcre", "universal"])
        #expect(d.dependencies == ["pcre2", "libiconv"])
        #expect(d.installerNeedsRoot == nil)
    }

    @Test func infoIntelFromCapture() async throws {
        let (e, _) = engine("figlet", try fixture("x86_64/info-figlet.txt"))
        let d = try await e.info(ref("figlet"))
        #expect(d.summary == "banner-like program prints strings as ASCII art")
        #expect(d.homepage == URL(string: "http://www.figlet.org/"))
        #expect(d.latestVersion == "2.2.5")
        #expect(d.variants == ["universal"])
        #expect(d.dependencies == [])
    }

    @Test func infoMergesRunDependenciesWithoutDuplicates() async throws {
        // The real ripgrep capture with its (empty) depends_run line filled in.
        let text = try fixture("info-ripgrep.txt").replacingOccurrences(of: "depends_run: \n", with: "depends_run: libiconv, zlib, pcre2\n")
        #expect(text.contains("zlib"))
        let (e, _) = engine("ripgrep", text)
        let d = try await e.info(ref("ripgrep"))
        #expect(d.dependencies == ["pcre2", "libiconv", "zlib"])
    }

    @Test func infoFailsOnUnreadableOutput() async {
        for result in [ok(""), ok("Error: something odd\n"), ok("description: x\nhomepage: https://x.example\n"),
                       CommandResult(exitCode: 1, stdout: "", stderr: "Error: Port nope not found")] {
            let runner = FakeRunner([infoArgs + ["ripgrep"]: result])
            let e = MacPortsEngine(runner: runner, executable: port)
            await #expect(throws: EngineError.self) { try await e.info(ref("ripgrep")) }
        }
    }

    @Test func infoRejectsNamesThatArentLiteralPorts() async {
        let runner = FakeRunner([:])
        let e = MacPortsEngine(runner: runner, executable: port)
        for name in ["--evil", "all", "rip*", "name:regex", ""] {
            await #expect(throws: EngineError.self) { try await e.info(ref(name)) }
        }
        await #expect(throws: EngineError.self) { try await e.info(ref("ripgrep", engine: .homebrew)) }
        #expect(runner.calls.isEmpty)
    }
}

// MARK: requested variants (Plan 4 Task 3)

extension MacPortsEngineTests {
    @Test func requestedVariantsParsed() async throws {
        let (e, _) = engine([["-v", "-q", "installed", "active"]: ok(try fixture("installed.txt"))])
        let pkgs = try await e.listInstalled()
        let byName = Dictionary(uniqueKeysWithValues: pkgs.map { ($0.id.name, $0) })
        #expect(byName["bzip2"]?.requestedVariants == ["+universal"])
        #expect(byName["bzip2"]?.installedVersion == "1.0.8_1")
        #expect(byName["autoconf"]?.requestedVariants == [])
    }

    @Test func requestedVariantsFieldEdgeCases() {
        // Not captures: the field's own edges, cut from the captured line shape.
        #expect(MacPortsEngine.requestedVariants(in: "  x @1_0 (active) platform='darwin 27'") == [])
        #expect(MacPortsEngine.requestedVariants(in: "  x @1_0 (active) requested_variants=''") == [])
        #expect(MacPortsEngine.requestedVariants(in: "  x @1_0+a+b (active) requested_variants='+universal-x11+quartz'")
                == ["+universal", "-x11", "+quartz"])
        #expect(MacPortsEngine.requestedVariants(in: "  x @1_0 (active) requested_variants='+universal") == [])
    }
}
