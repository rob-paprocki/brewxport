import Testing
import BrewxPortCore
@testable import BrewxPortUI

@Suite struct MoveSheetTextTests {
    static func formula(_ engine: EngineID, _ name: String, installed: String? = "1",
                        latest: String? = "1") -> Package {
        Package(id: PackageRef(engine: engine, kind: engine == .macports ? .port : .formula, name: name),
                displayName: name, installedVersion: installed, latestVersion: latest)
    }

    static func item(_ name: String, from source: EngineID = .homebrew, to target: EngineID = .nanobrew,
                     old: String = "14.1.1", new: String = "14.1.1", needsInstall: Bool = true) -> MoveItem {
        MoveItem(old: formula(source, name, installed: old, latest: old),
                 new: formula(target, name, installed: needsInstall ? nil : new, latest: new),
                 needsInstall: needsInstall, wasRequested: true)
    }

    static func plan(source: EngineID = .homebrew, target: EngineID = .nanobrew, moving: [MoveItem]? = nil,
                     cantMove: [CantMove] = [], leftovers: [Package] = []) -> MovePlan {
        MovePlan(picked: formula(source, "ripgrep", installed: "14.1.1"), target: target,
                 moving: moving ?? [item("ripgrep", from: source, to: target)], cantMove: cantMove,
                 keepPicked: !cantMove.isEmpty, leftovers: leftovers, removeLeftovers: true, pathWarning: nil)
    }

    @Test func sheetTextCounts() {
        #expect(MoveSheetText.moveButton(count: 1) == "Move 1 package")
        #expect(MoveSheetText.moveButton(count: 3) == "Move 3 packages")
        #expect(MoveSheetText.title(Self.plan()) == "Move ripgrep to nanobrew")
        #expect(MoveSheetText.movesTo(Self.plan()) == "Moves to nanobrew")
        #expect(MoveSheetText.direction(Self.plan()) == "Homebrew → nanobrew")
        #expect(MoveSheetText.checking == "Checking…")
    }

    @Test func sheetTextRows() {
        let plan = Self.plan(moving: [Self.item("ripgrep"), Self.item("ripgrep-all", old: "0.10.6", new: "0.10.9")])
        #expect(plan.moving.map { MoveSheetText.name($0, in: plan) } == ["ripgrep", "ripgrep-all (needs it)"])
        #expect(plan.moving.map(MoveSheetText.versions) == ["14.1.1 → 14.1.1", "0.10.6 → 0.10.9"])
        // Already on the target: its installed version.
        let there = Self.item("ripgrep", old: "14.1.0", new: "14.1.1", needsInstall: false)
        #expect(MoveSheetText.versions(there) == "14.1.0 → 14.1.1")
        // An unknown version shows as a dash rather than a blank.
        let unknown = MoveItem(old: Self.formula(.homebrew, "x", installed: nil, latest: nil),
                               new: Self.formula(.nanobrew, "x", installed: nil, latest: nil),
                               needsInstall: true, wasRequested: true)
        #expect(MoveSheetText.versions(unknown) == "– → –")
    }

    @Test func sheetTextCantMoveLine() {
        let plan = Self.plan(cantMove: [CantMove(name: "ripgrep-all", reason: "not on nanobrew")])
        #expect(MoveSheetText.cantMoveLine(plan.cantMove[0], in: plan)
                    == "ripgrep-all isn't on nanobrew, so ripgrep's Homebrew copy stays.")
        // A lookup that threw with "couldn't find it" reads the same way.
        let lookup = CantMove(name: "ripgrep-all", reason: "couldn't find it on nanobrew")
        #expect(MoveSheetText.cantMoveLine(lookup, in: plan)
                    == "ripgrep-all isn't on nanobrew, so ripgrep's Homebrew copy stays.")
        // Any other reason is shown as it is.
        for reason in ["needed by ripgrep-all", "nanobrew didn't answer in time", "from a third-party tap",
                       "a Homebrew app"] {
            #expect(MoveSheetText.cantMoveLine(CantMove(name: "rga", reason: reason), in: plan) == "rga: \(reason)")
        }
        // The picked package itself: nothing moves, so no copy "stays" for something else.
        let stuck = Self.plan(moving: [], cantMove: [CantMove(name: "ripgrep", reason: "not on nanobrew")])
        #expect(MoveSheetText.cantMoveLine(stuck.cantMove[0], in: stuck) == "ripgrep isn't on nanobrew, so it can't move.")
        let timedOut = Self.plan(moving: [], cantMove: [CantMove(name: "ripgrep", reason: "nanobrew didn't answer in time")])
        #expect(MoveSheetText.cantMoveLine(timedOut.cantMove[0], in: timedOut)
                    == "ripgrep: nanobrew didn't answer in time")
        for line in [MoveSheetText.cantMoveLine(plan.cantMove[0], in: plan),
                     MoveSheetText.cantMoveLine(stuck.cantMove[0], in: stuck)] {
            #expect(!line.contains("—"))
        }
    }

    static func keptCopyCount(_ lines: [String]) -> Int {
        lines.filter { $0.contains("ripgrep's Homebrew copy stays.") }.count
    }

    @Test func keptCopyLineForTimeout() {
        let plan = Self.plan(cantMove: [CantMove(name: "ripgrep-all", reason: "nanobrew didn't answer in time")])
        #expect(MoveSheetText.cantMoveLines(plan) == ["ripgrep-all: nanobrew didn't answer in time",
                                                      "ripgrep's Homebrew copy stays."])
    }

    @Test func keptCopyLineForNeededBy() {
        let plan = Self.plan(cantMove: [CantMove(name: "rga", reason: "a Homebrew app"),
                                        CantMove(name: "ripgrep-all", reason: "needed by rga")])
        #expect(MoveSheetText.cantMoveLines(plan) == ["rga: a Homebrew app", "ripgrep-all: needed by rga",
                                                      "ripgrep's Homebrew copy stays."])
        let unlisted = Self.plan(cantMove: [CantMove(name: "x", reason: "not listed on Homebrew")])
        #expect(Self.keptCopyCount(MoveSheetText.cantMoveLines(unlisted)) == 1)
    }

    @Test func keptCopyLineNotDuplicated() {
        // One not-found line already says it.
        let one = Self.plan(cantMove: [CantMove(name: "ripgrep-all", reason: "not on nanobrew"),
                                       CantMove(name: "x", reason: "nanobrew didn't answer in time")])
        #expect(MoveSheetText.cantMoveLines(one) == ["ripgrep-all isn't on nanobrew, so ripgrep's Homebrew copy stays.",
                                                     "x: nanobrew didn't answer in time"])
        // Two not-found lines: only the first says it.
        let two = Self.plan(cantMove: [CantMove(name: "a", reason: "not on nanobrew"),
                                       CantMove(name: "b", reason: "couldn't find it on nanobrew")])
        #expect(MoveSheetText.cantMoveLines(two) == ["a isn't on nanobrew, so ripgrep's Homebrew copy stays.",
                                                     "b isn't on nanobrew."])
        // Nothing moves: no kept-copy line, only the reason.
        let stuck = Self.plan(moving: [], cantMove: [CantMove(name: "ripgrep", reason: "nanobrew didn't answer in time")])
        #expect(MoveSheetText.cantMoveLines(stuck) == ["ripgrep: nanobrew didn't answer in time"])
        // Nothing kept: no lines.
        #expect(MoveSheetText.cantMoveLines(Self.plan()).isEmpty)
    }

    @Test func sheetTextPasswordLine() {
        #expect(MoveSheetText.passwordLine(Self.plan()) == "Homebrew and nanobrew don't need your password.")
        #expect(MoveSheetText.passwordLine(Self.plan(source: .nanobrew, target: .homebrew))
                    == "nanobrew and Homebrew don't need your password.")
        #expect(MoveSheetText.passwordLine(Self.plan(target: .macports)) == "You'll be asked for your password once.")
        #expect(MoveSheetText.passwordLine(Self.plan(source: .macports, target: .nanobrew))
                    == "You'll be asked for your password once.")
    }

    @Test func sheetTextLeftovers() {
        let pcre2 = Self.formula(.homebrew, "pcre2"), oniguruma = Self.formula(.homebrew, "oniguruma")
        let plan = Self.plan(leftovers: [pcre2])
        #expect(MoveSheetText.leftoversToggle(plan) == "Also remove leftovers from Homebrew")
        #expect(MoveSheetText.leftoverNames([pcre2]) == "pcre2 (nothing else uses it)")
        #expect(MoveSheetText.leftoverNames([oniguruma, pcre2]) == "oniguruma, pcre2 (nothing else uses them)")
    }

    @Test func sheetTextPathFix() {
        #expect(MoveSheetText.addToPath == "Add to PATH")
        #expect(MoveSheetText.addsLine(to: "~/.zprofile") == "Adds this line to ~/.zprofile:")
        #expect(MoveSheetText.copyCaption(hint: nil) == "Add this line to your shell's startup file:")
        #expect(MoveSheetText.copyCaption(hint: "~/.profile") == "Add this line to ~/.profile:")
        #expect(MoveSheetText.copy == "Copy")
        #expect(MoveSheetText.notInDemo == "Not available in demo mode")
        let plan = Self.plan()
        #expect(MoveSheetText.pathFixDone(.added(file: "~/.zprofile"), plan)
                    == "Added to ~/.zprofile. Open a new Terminal window to use ripgrep.")
        #expect(MoveSheetText.pathFixDone(.alreadyPresent(file: "~/.bash_profile"), plan)
                    == "Already in ~/.bash_profile")
        #expect(MoveSheetText.pathFixFailure(.unknownDirectory)
                    == "BrewxPort only adds Homebrew, nanobrew and MacPorts folders to your PATH.")
        #expect(MoveSheetText.pathFixFailure(.copyOnly)
                    == "BrewxPort can't change your shell's startup file. Copy the line instead.")
        #expect(MoveSheetText.pathFixFailure(.notARegularFile(file: "~/.zprofile"))
                    == "~/.zprofile isn't a regular file, so BrewxPort didn't change it.")
        #expect(MoveSheetText.pathFixFailure(.notYours(file: "~/.zprofile"))
                    == "~/.zprofile belongs to another user, so BrewxPort didn't change it.")
        #expect(MoveSheetText.pathFixFailure(.couldNotWrite(file: "~/.zprofile", reason: "Permission denied"))
                    == "BrewxPort couldn't change ~/.zprofile: Permission denied.")
        // No em dashes anywhere in the new copy.
        let all = [MoveSheetText.addToPath, MoveSheetText.addsLine(to: "~/.zprofile"), MoveSheetText.copyCaption(hint: nil),
                   MoveSheetText.notInDemo, MoveSheetText.pathFixDone(.added(file: "~/.zprofile"), plan)]
        #expect(!all.joined().contains("\u{2014}"))
    }
}
