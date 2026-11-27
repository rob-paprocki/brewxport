import Foundation
import Testing
@testable import BrewxPortCore

/// Runs against a temporary folder of fake installs (executable files and symlinks), never the Mac's real tools.
@Suite struct ToolLocatorTests {
    /// A temporary folder laid out like a Mac with nvm's Node, Homebrew's Node and an fnm-style per-shell link.
    final class Layout {
        let root: String
        /// `root` with symlinks resolved (/var is /private/var), as realpath gives it.
        let real: String

        init() throws {
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("brewxport-tools-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            root = base.path
            real = try #require(ToolLocator.realPath(root))
            // nvm: bin/npm is a symlink to the npm-cli.js script, as npm installs itself.
            try executable("nvm/versions/node/v22.11.0/lib/node_modules/npm/bin/npm-cli.js")
            try executable("nvm/versions/node/v22.11.0/bin/node")
            try FileManager.default.createSymbolicLink(
                atPath: path("nvm/versions/node/v22.11.0/bin/npm"),
                withDestinationPath: "../lib/node_modules/npm/bin/npm-cli.js")
            try executable("homebrew/bin/npm")
            try executable("homebrew/bin/node")
            // fnm: the login PATH holds a per-shell link to the version's bin folder.
            try FileManager.default.createDirectory(atPath: path("fnm_multishells"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: path("fnm_multishells/4242_1"),
                                                       withDestinationPath: path("nvm/versions/node/v22.11.0/bin"))
            // Not tools: a plain file and a folder that happen to be called npm.
            try file("plain/bin/npm", mode: 0o644)
            try FileManager.default.createDirectory(atPath: path("folder/bin/npm"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        func path(_ relative: String) -> String { root + "/" + relative }
        func realPath(_ relative: String) -> String { real + "/" + relative }

        private func executable(_ relative: String) throws { try file(relative, mode: 0o755) }

        private func file(_ relative: String, mode: Int) throws {
            let url = URL(fileURLWithPath: path(relative))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    @Test func locatorPrefersLoginShellCopy() throws {
        let layout = try Layout()
        let locator = ToolLocator()
        let nvmBin = layout.path("nvm/versions/node/v22.11.0/bin")
        let brewBin = layout.path("homebrew/bin")
        // nvm's npm first on the login PATH, Homebrew's in a fixed place: the login shell's copy wins.
        let found = locator.locate("npm", loginPath: ["/nonexistent/bin", nvmBin], fixed: [brewBin])
        #expect(found?.path == layout.realPath("nvm/versions/node/v22.11.0/bin/npm"))
        // Not on the login PATH: the first fixed location that has it.
        #expect(locator.locate("npm", loginPath: ["/nonexistent/bin"], fixed: ["/nonexistent/2", brewBin])?.path
                == layout.realPath("homebrew/bin/npm"))
        #expect(locator.locate("npm", loginPath: [], fixed: []) == nil)
        #expect(locator.locate("cargo", loginPath: [nvmBin], fixed: [brewBin]) == nil)
    }

    @Test func resolvesTheFolderButKeepsTheToolsOwnName() throws {
        let layout = try Layout()
        // fnm's per-shell link is resolved to the real folder. npm itself stays `…/bin/npm`, not npm-cli.js, so
        // its folder (with the matching node) can go first on PATH, and rustup-style proxies keep their argv[0].
        let found = ToolLocator().locate("npm", loginPath: [layout.path("fnm_multishells/4242_1")], fixed: [])
        #expect(found?.path == layout.realPath("nvm/versions/node/v22.11.0/bin/npm"))
    }

    @Test func skipsWhatIsntAnExecutableFile() throws {
        let layout = try Layout()
        let locator = ToolLocator()
        let found = locator.locate("npm", loginPath: [layout.path("plain/bin"), layout.path("folder/bin")],
                                   fixed: [layout.path("homebrew/bin")])
        #expect(found?.path == layout.realPath("homebrew/bin/npm"))
    }

    @Test func refusesRelativeFoldersAndToolPaths() throws {
        let layout = try Layout()
        let locator = ToolLocator()
        // Relative entries would depend on the working directory; skipped.
        #expect(locator.locate("npm", loginPath: ["homebrew/bin", ".", "~/bin", ""], fixed: []) == nil)
        // The tool is a plain name, never a path.
        for tool in ["bin/npm", "../npm", "/usr/bin/true", "", ".", ".."] {
            #expect(locator.locate(tool, loginPath: [layout.path("homebrew"), layout.path("homebrew/bin")],
                                   fixed: ["/"]) == nil, "\(tool)")
        }
    }
}
