import Testing
import Foundation
@testable import BrewxPortCore

@Suite struct EngineLocatorTests {
    @Test func brewPrefersOptHomebrewOnArm() {
        #expect(EngineLocator().candidates(for: .homebrew, arch: .arm64).first == "/opt/homebrew/bin/brew")
    }

    @Test func brewPrefersUsrLocalOnIntel() {
        #expect(EngineLocator().candidates(for: .homebrew, arch: .x86_64).first == "/usr/local/bin/brew")
    }

    @Test func masFollowsBrewOrder() {
        let l = EngineLocator()
        #expect(l.candidates(for: .mas, arch: .arm64) == ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"])
        #expect(l.candidates(for: .mas, arch: .x86_64) == ["/usr/local/bin/mas", "/opt/homebrew/bin/mas"])
    }

    @Test func nanobrewCandidates() {
        let l = EngineLocator()
        #expect(l.candidates(for: .nanobrew, arch: .arm64) == ["/opt/nanobrew/prefix/bin/nb", "/opt/nb/bin/nb"])
        #expect(l.candidates(for: .nanobrew, arch: .x86_64) == ["/opt/nanobrew/prefix/bin/nb", "/opt/nb/bin/nb"])
    }

    @Test func macportsPath() {
        #expect(EngineLocator().candidates(for: .macports, arch: .arm64) == ["/opt/local/bin/port"])
        #expect(EngineLocator().candidates(for: .macports, arch: .x86_64) == ["/opt/local/bin/port"])
    }

    @Test func overrideWins() {
        let l = EngineLocator(isExecutable: { _ in true }, overrides: [.homebrew: "/x/brew"])
        #expect(l.locate(.homebrew, arch: .arm64) == URL(fileURLWithPath: "/x/brew"))
    }

    @Test func overrideNotExecutableFallsBack() {
        let l = EngineLocator(isExecutable: { $0 == "/usr/local/bin/brew" }, overrides: [.homebrew: "/x/brew"])
        #expect(l.locate(.homebrew, arch: .arm64) == URL(fileURLWithPath: "/usr/local/bin/brew"))
    }

    @Test func firstExecutableCandidateWins() {
        let l = EngineLocator(isExecutable: { _ in true })
        #expect(l.locate(.homebrew, arch: .arm64) == URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
    }

    @Test func missingWhenNothingExecutable() {
        let l = EngineLocator(isExecutable: { _ in false })
        #expect(l.locate(.homebrew, arch: .arm64) == nil)
    }

    @Test func queryStartingWithDashIsNotAnOption() throws {
        #expect(try searchArguments(["search"], query: "--force", engine: .homebrew) == ["search", "--", "--force"])
    }

    @Test func separatorCanBeTurnedOff() throws {
        #expect(try searchArguments(["search"], query: " -x ", engine: .nanobrew, separator: false) == ["search", "-x"])
        #expect(throws: EngineError.self) { try searchArguments(["search"], query: " ", engine: .nanobrew, separator: false) }
    }

    @Test func plainQueryIsAppendedAndTrimmed() throws {
        #expect(try searchArguments(["search"], query: "  wget \n", engine: .homebrew) == ["search", "wget"])
    }

    @Test func emptyQueryThrows() {
        #expect(throws: EngineError(engine: .macports, message: "Search query is empty")) {
            try searchArguments(["search"], query: "  \t", engine: .macports)
        }
    }

    @Test func packageNamesRejectLeadingDash() {
        let r = PackageRef(engine: .homebrew, kind: .formula, name: "--force")
        #expect(throws: EngineError.self) { _ = try packageNameArguments([r], engine: .homebrew) }
    }

    @Test func packageNamesRejectEmpty() {
        let r = PackageRef(engine: .homebrew, kind: .formula, name: "  ")
        #expect(throws: EngineError.self) { _ = try packageNameArguments([r], engine: .homebrew) }
        #expect(throws: EngineError.self) { _ = try packageNameArguments([], engine: .homebrew) }
    }

    @Test func launchFailureOnExistingFileIsUnusable() async {
        let sh = URL(fileURLWithPath: "/bin/sh")
        let engines: [any Engine] = [
            HomebrewEngine(runner: ThrowingRunner(), executable: sh),
            NanobrewEngine(runner: ThrowingRunner(), executable: sh),
            MacPortsEngine(runner: ThrowingRunner(), executable: sh),
            MasEngine(runner: ThrowingRunner(), executable: sh),
        ]
        for e in engines {
            let status = await e.detect()
            #expect(isUnusable(status, at: sh), "\(e.id)")
            if case .unusable(_, let reason) = status { #expect(reason.contains("Bad CPU type"), "\(e.id)") }
        }
    }

    @Test func launchFailureOnVanishedFileIsMissing() async {
        let gone = URL(fileURLWithPath: "/nonexistent/brewxport-test/brew")
        #expect(await HomebrewEngine(runner: ThrowingRunner(), executable: gone).detect() == .missing)
        #expect(await MasEngine(runner: ThrowingRunner(), executable: gone).detect() == .missing)
    }

    @Test func packageNamesKeepAtSignAndPlus() throws {
        let refs = ["python@3.12", "gtk+3"].map { PackageRef(engine: .homebrew, kind: .formula, name: $0) }
        #expect(try packageNameArguments(refs, engine: .homebrew) == ["python@3.12", "gtk+3"])
    }
}
