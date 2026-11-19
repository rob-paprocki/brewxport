# Notes for coding agents

## How this project is published

Development happens in a separate repository. The public repository gets one commit per released
version and nothing else.

If there's a `private/` folder at the top of the repository, you're in the development repository.
Read `private/README.md` before you change anything. It says what may and may not reach the public
repository. When you're asked to cut a release, follow `private/RELEASING.md`.

If there's no `private/` folder, you're in the public repository. Don't commit or push here. A commit on
its `main` stops the next release until someone removes it. To suggest a change, open an issue or a pull
request. It won't be merged here, but it can be copied into the development repository and ship with the
next release.

## This project

BrewxPort is a native macOS app (Swift 6, SwiftUI, macOS 15+, universal Intel and Apple Silicon) that drives
Homebrew, nanobrew, MacPorts and mas from one window.

- Design notes: `private/design/`. Plans: `private/plans/`, one per milestone.
- Core logic lives in the Swift package `BrewxPortCore`. Run its tests with `swift test` from the repository root.
- Engines are driven through their command lines with argument arrays, never shell strings. GUI apps don't
  inherit the shell's PATH, so engines are found at fixed paths (see `EngineLocator`).
- Parser tests use real captured engine output under `Tests/BrewxPortCoreTests/Fixtures/<engine>/`. Never
  hand-write a fixture.
- Anything that installs, upgrades or removes packages is tested in a throwaway macOS VM, never on a daily
  machine. Intel is tested under Rosetta (`arch -x86_64`) in that VM.
- `brew` and `nb` never run as root. Root work goes through the BrewxPortHelper daemon with a per-run
  authorization.
