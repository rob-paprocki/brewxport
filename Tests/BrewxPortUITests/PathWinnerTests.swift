import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@Suite struct PathWinnerTests {
    static let binDirs: [EngineID: String] = [
        .nanobrew: "/opt/nanobrew/prefix/bin", .macports: "/opt/local/bin", .homebrew: "/opt/homebrew/bin",
    ]
    static let path = ["/usr/bin", "/opt/local/bin/", "/opt/nanobrew/prefix/bin", "/opt/homebrew/bin"]

    @Test func pathWinnerFirstDirWithFile() {
        // MacPorts comes first on the PATH but has no figlet; nanobrew is the next one that does.
        let files: Set = ["/opt/nanobrew/prefix/bin/figlet", "/opt/homebrew/bin/figlet", "/usr/bin/other"]
        #expect(PathWinner.winner(command: "figlet", path: Self.path, binDirs: Self.binDirs,
                                  exists: { files.contains($0) }) == .nanobrew)
        // A trailing slash on the PATH entry still matches the engine's bin directory.
        let ports: Set = ["/opt/local/bin/figlet", "/opt/homebrew/bin/figlet"]
        #expect(PathWinner.winner(command: "figlet", path: Self.path, binDirs: Self.binDirs,
                                  exists: { ports.contains($0) }) == .macports)
    }

    @Test func pathWinnerNilWhenNoFileNamedLikePackage() {
        // ripgrep's command is rg, so no bin directory holds a file called ripgrep.
        let files: Set = ["/opt/nanobrew/prefix/bin/rg", "/opt/homebrew/bin/rg"]
        #expect(PathWinner.winner(command: "ripgrep", path: Self.path, binDirs: Self.binDirs,
                                  exists: { files.contains($0) }) == nil)
        // A copy outside every engine's bin directory that comes first runs; no engine wins.
        let system: Set = ["/usr/bin/figlet", "/opt/homebrew/bin/figlet"]
        #expect(PathWinner.winner(command: "figlet", path: Self.path, binDirs: Self.binDirs,
                                  exists: { system.contains($0) }) == nil)
        #expect(PathWinner.firstDirectory(holding: "figlet", path: Self.path, exists: { system.contains($0) })
                == "/usr/bin")
        // A bin directory that isn't on the PATH never wins.
        #expect(PathWinner.winner(command: "figlet", path: ["/usr/bin"], binDirs: Self.binDirs,
                                  exists: { _ in true }) == nil)
    }
}
