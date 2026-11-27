import Foundation
import BrewxPortCore
import BrewxPortUI

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: brewxport-smoke <query> | login-path [--same-session] [--shell PATH]\n".utf8))
    exit(1)
}

// `login-path`: the app's own login-shell PATH probe, printed as "source: …", "note: …", "variables: …" (the names
// of the captured location variables only, never their values) and one PATH entry per line.
// `--same-session` turns off the new session (to show the hang on a terminal); `--shell` replaces pw_shell.
if CommandLine.arguments[1] == "login-path" {
    let options = Array(CommandLine.arguments.dropFirst(2))
    var shell = LoginShellPath.userShell()
    if let i = options.firstIndex(of: "--shell"), i + 1 < options.count { shell = options[i + 1] }
    let resolver = LoginShellPath(runner: ProcessRunner(), shell: shell, allowedShells: LoginShellPath.allowedShells(),
                                  systemPaths: { LoginShellPath.systemPaths() },
                                  newSession: !options.contains("--same-session"))
    let resolved = await resolver.resolve()
    print("source: \(resolved.source == .loginShell ? "loginShell" : "systemDefault")")
    if let note = resolved.note { print("note: \(note)") }
    print("variables: " + resolved.environment.keys.sorted().joined(separator: " "))
    for entry in resolved.entries { print(entry) }
    exit(0)
}
let query = CommandLine.arguments[1]
let arch = Arch.current
let locator = EngineLocator()
let runner = ProcessRunner()

func path(_ id: EngineID) -> URL? { locator.locate(id, arch: arch) }
let engines: [any Engine] = [
    HomebrewEngine(runner: runner, executable: path(.homebrew)),
    NanobrewEngine(runner: runner, executable: path(.nanobrew)),
    MacPortsEngine(runner: runner, executable: path(.macports)),
    MasEngine(runner: runner, executable: path(.mas)),
]
let catalog = PackageCatalog(engines: engines, arch: arch)

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

func table(_ title: String, _ result: CatalogResult) {
    print("\n\(title) (\(result.packages.count))")
    for p in result.packages {
        let version = p.latestVersion ?? p.installedVersion ?? "-"
        print("  \(pad(p.displayName, 32)) \(pad(version, 16)) \(p.id.engine.rawValue)/\(p.id.kind.rawValue)")
    }
}

print("Architecture: \(arch.rawValue)")
print("Engines")
let status = await catalog.presentEngines()
for id in EngineID.allCases {
    switch status[id] {
    case .present(let path, let version)?: print("  \(pad(id.rawValue, 9)) \(version)  \(path.path)")
    case .unusable(let path, let reason)?: print("  \(pad(id.rawValue, 9)) unusable  \(path.path): \(reason)")
    case .unsupported(let path, let version, _)?: print("  \(pad(id.rawValue, 9)) \(version) too old  \(path.path)")
    case .missing?, nil: print("  \(pad(id.rawValue, 9)) missing")
    }
}

let found = await catalog.search(query)
table("Search \"\(query)\"", found)
let old = await catalog.outdated()
table("Outdated", old)

let errors = found.errors + old.errors
print("\nErrors (\(errors.count))")
for e in errors { print("  \(e.engine.rawValue): \(e.message)") }
