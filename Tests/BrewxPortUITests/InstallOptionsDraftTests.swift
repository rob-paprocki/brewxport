import BrewxPortCore
import Testing
@testable import BrewxPortUI

struct InstallOptionsDraftTests {
    @Test func extraArgsSplitOnWhitespaceNoShell() throws {
        let draft = InstallOptionsDraft(extraArgs: "-s  -b")
        let options = try draft.options(for: .macports, capabilities: [.sourceBuilds])
        #expect(options.extraArgs == ["-s", "-b"])
        #expect(options.version == nil)
        #expect(options.variants.isEmpty)

        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(extraArgs: "$(touch x)").options(for: .homebrew, capabilities: [.casks])
        }
        // A dash-led token is fine for engines without an allow-list; nothing is split on quotes or semicolons.
        let brew = try InstallOptionsDraft(extraArgs: "--HEAD\t--debug").options(for: .homebrew, capabilities: [])
        #expect(brew.extraArgs == ["--HEAD", "--debug"])
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(extraArgs: "-s ;").options(for: .homebrew, capabilities: [])
        }
    }

    @Test func macPortsExtraArgOutsideAllowListRejected() {
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(extraArgs: "-f").options(for: .macports, capabilities: [.sourceBuilds])
        }
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(extraArgs: "-s -f").options(for: .macports, capabilities: [.sourceBuilds])
        }
    }

    @Test func masTakesNoExtraArgs() throws {
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(extraArgs: "-s").options(for: .mas, capabilities: [])
        }
        let empty = try InstallOptionsDraft(extraArgs: "   ").options(for: .mas, capabilities: [])
        #expect(empty == InstallOptions())
    }

    @Test func variantsBecomePlusMinus() throws {
        let draft = InstallOptionsDraft(variants: ["universal": false, "x11": true, "gtk": true])
        let options = try draft.options(for: .macports, capabilities: [.sourceBuilds])
        #expect(options.variants == ["+gtk", "-universal", "+x11"])
    }

    @Test func invalidVariantNameRejected() {
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(variants: ["x y": true]).options(for: .macports, capabilities: [])
        }
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(variants: ["s": true]).options(for: .macports, capabilities: [])
        }
    }

    @Test func versionRejectedWithoutPinning() throws {
        #expect(throws: EngineError.self) {
            try InstallOptionsDraft(version: "1.2").options(for: .homebrew, capabilities: [.casks])
        }
        let pinned = try InstallOptionsDraft(version: " 1.2 ").options(for: .homebrew, capabilities: [.versionPinning])
        #expect(pinned.version == "1.2")
        let blank = try InstallOptionsDraft(version: "  ").options(for: .homebrew, capabilities: [])
        #expect(blank.version == nil)
    }
}
