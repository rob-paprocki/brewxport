import Testing
import Foundation
@testable import BrewxPortUI

/// Every test works in its own temporary home; nothing here touches the real one.
@Suite struct ShellPathEditorTests {
    static let bin = "/opt/nanobrew/prefix/bin"
    static let line = #"export PATH="/opt/nanobrew/prefix/bin:$PATH"  # Added by BrewxPort"#

    static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShellPathEditorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// The offer to append to `relative` inside `home`, shown as `~/<relative>`.
    static func appending(_ home: URL, _ relative: String) -> ShellPathEditor.Offer {
        .append(ShellPathEditor.Target(file: "~/" + relative, path: home.path + "/" + relative))
    }

    @Test func lineIsExact() {
        #expect(ShellPathEditor.line(for: Self.bin) == Self.line)
        #expect(ShellPathEditor.line(for: "/opt/homebrew/bin")
                    == #"export PATH="/opt/homebrew/bin:$PATH"  # Added by BrewxPort"#)
    }

    @Test func appendsLineToZprofile() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        try "export EDITOR=vim\n".write(to: file, atomically: false, encoding: .utf8)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        #expect(editor.offer == Self.appending(home, ".zprofile"))
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(file) == "export EDITOR=vim\n" + Self.line + "\n")
    }

    /// A language manager's bin folder (`~/.cargo/bin`) is in no fixed list, so it's written only when the caller names
    /// it as one an engine reported, and only when it's a plain path: anything a shell would read as code (`$`, a
    /// backtick, a quote, a backslash, a new line) is refused, allowed or not, and nothing is written.
    @Test func languageBinFolderOnlyWhenPlain() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        let cargo = home.path + "/.cargo/bin"
        #expect(throws: ShellPathEditor.Failure.unknownDirectory) { try editor.add(cargo, to: editor.offer) }
        #expect(try editor.add(cargo, to: editor.offer, allowing: [cargo]) == .added(file: "~/.zprofile"))
        #expect(try Self.read(file) == "export PATH=\"\(cargo):$PATH\"  # Added by BrewxPort\n")
        for unsafe in [home.path + "/$(touch x)/bin", home.path + "/`id`/bin", home.path + "/a\"b/bin",
                       home.path + "/a\\b/bin", home.path + "/a\nb/bin", "relative/bin", home.path + "/../x/bin"] {
            #expect(!ShellPathEditor.isPlainPath(unsafe), "\(unsafe)")
            #expect(throws: ShellPathEditor.Failure.unknownDirectory) {
                try editor.add(unsafe, to: editor.offer, allowing: [unsafe])
            }
        }
        #expect(ShellPathEditor.isPlainPath("/Users/Zoë Smith/.local/bin"))
        #expect(try Self.read(file) == "export PATH=\"\(cargo):$PATH\"  # Added by BrewxPort\n")
    }

    @Test func createsFileWhenMissing() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(file) == Self.line + "\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
    }

    @Test func doesNothingWhenAlreadyPresent() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        // Someone's own export of the same directory counts.
        let own = "export PATH=/opt/nanobrew/prefix/bin:$PATH\n"
        try own.write(to: file, atomically: false, encoding: .utf8)
        #expect(try editor.add(Self.bin, to: editor.offer) == .alreadyPresent(file: "~/.zprofile"))
        #expect(try Self.read(file) == own)
        // So does our own line, and adding twice writes it once.
        try "".write(to: file, atomically: false, encoding: .utf8)
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try editor.add(Self.bin, to: editor.offer) == .alreadyPresent(file: "~/.zprofile"))
        #expect(try Self.read(file) == Self.line + "\n")
        // A commented-out export and a longer directory with the same start don't count.
        let near = "# export PATH=/opt/nanobrew/prefix/bin:$PATH\nexport PATH=/opt/nanobrew/prefix/binx:$PATH\n"
        try near.write(to: file, atomically: false, encoding: .utf8)
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(file) == near + Self.line + "\n")
    }

    @Test func refusesUnknownBinDir() throws {
        let home = try Self.home()
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        for bin in ["/tmp/evil", "/opt/homebrew/bin/../../tmp", "/opt/nanobrew/prefix/bin\"; rm -rf ~; \""] {
            #expect(throws: ShellPathEditor.Failure.unknownDirectory) { try editor.add(bin, to: editor.offer) }
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zprofile").path))
        // Every engine's own bin directory is known, with or without a trailing slash.
        for bin in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/nanobrew/prefix/bin", "/opt/nb/bin", "/opt/local/bin/"] {
            #expect(ShellPathEditor.isKnown(bin))
        }
    }

    @Test func refusesNonRegularFile() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        #expect(throws: ShellPathEditor.Failure.notARegularFile(file: "~/.zprofile")) {
            try editor.add(Self.bin, to: editor.offer)
        }
        // A symlink to a regular file is fine; a dangling one is refused rather than creating its target.
        try FileManager.default.removeItem(at: file)
        let real = home.appendingPathComponent("dotfiles-zprofile")
        try "x=1".write(to: real, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(real) == "x=1\n" + Self.line + "\n")
        try FileManager.default.removeItem(at: file)
        let missing = home.appendingPathComponent("nowhere")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: missing)
        #expect(throws: ShellPathEditor.Failure.notARegularFile(file: "~/.zprofile")) {
            try editor.add(Self.bin, to: editor.offer)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func refusesFileOwnedBySomeoneElse() throws {
        let home = try Self.home()
        try "".write(to: home.appendingPathComponent(".zprofile"), atomically: false, encoding: .utf8)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh", owner: getuid() + 1)
        #expect(throws: ShellPathEditor.Failure.notYours(file: "~/.zprofile")) {
            try editor.add(Self.bin, to: editor.offer)
        }
        #expect(try Self.read(home.appendingPathComponent(".zprofile")) == "")
    }

    @Test func addsTrailingNewlineFirst() throws {
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        try "export EDITOR=vim".write(to: file, atomically: false, encoding: .utf8)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(file) == "export EDITOR=vim\n" + Self.line + "\n")
    }

    @Test func bashUsesBashProfile() throws {
        let home = try Self.home()
        let editor = ShellPathEditor(home: home, shell: "/opt/homebrew/bin/bash")
        #expect(editor.offer == Self.appending(home, ".bash_profile"))
        #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.bash_profile"))
        #expect(try Self.read(home.appendingPathComponent(".bash_profile")) == Self.line + "\n")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zprofile").path))
    }

    @Test func bashWithProfileOnlyOffersCopy() throws {
        // bash reads only the first of .bash_profile, .bash_login and .profile, so creating .bash_profile would hide
        // the one they use.
        for (existing, hint) in [(".profile", "~/.profile"), (".bash_login", "~/.bash_login")] {
            let home = try Self.home()
            try "export EDITOR=vim\n".write(to: home.appendingPathComponent(existing), atomically: false, encoding: .utf8)
            let editor = ShellPathEditor(home: home, shell: "/bin/bash")
            #expect(editor.offer == .copyOnly(hint: hint))
            #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: editor.offer) }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
            #expect(try Self.read(home.appendingPathComponent(existing)) == "export EDITOR=vim\n")
        }
        // With both, .bash_login comes first, as bash reads it.
        let home = try Self.home()
        try "".write(to: home.appendingPathComponent(".profile"), atomically: false, encoding: .utf8)
        try "".write(to: home.appendingPathComponent(".bash_login"), atomically: false, encoding: .utf8)
        #expect(ShellPathEditor(home: home, shell: "/bin/bash").offer == .copyOnly(hint: "~/.bash_login"))
        // An existing .bash_profile is still appended to, whatever else is there.
        try "".write(to: home.appendingPathComponent(".bash_profile"), atomically: false, encoding: .utf8)
        #expect(ShellPathEditor(home: home, shell: "/bin/bash").offer == Self.appending(home, ".bash_profile"))
    }

    @Test func zdotdirUsesItsZprofile() throws {
        for assignment in [#"export ZDOTDIR="$HOME/.config/zsh""#, "ZDOTDIR=~/.config/zsh",
                           "export ZDOTDIR=${HOME}/.config/zsh/", "ZDOTDIR='HOMEDIR/.config/zsh'",
                           #"export ZDOTDIR="$HOME/.config/zsh"  # where zsh lives"#,
                           "ZDOTDIR=$HOME/.config/zsh; export ZDOTDIR", "ZDOTDIR=~/.config/zsh\nexport ZDOTDIR",
                           "ZDOTDIR=/elsewhere\nZDOTDIR=$HOME/.config/zsh #later wins"] {
            let home = try Self.home()
            let dir = home.appendingPathComponent(".config/zsh")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let zshenv = "# zsh settings\n" + assignment.replacingOccurrences(of: "HOMEDIR", with: home.path) + "\n"
            try zshenv.write(to: home.appendingPathComponent(".zshenv"), atomically: false, encoding: .utf8)
            let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
            #expect(editor.offer == Self.appending(home, ".config/zsh/.zprofile"), "\(assignment)")
            #expect(try editor.add(Self.bin, to: editor.offer) == .added(file: "~/.config/zsh/.zprofile"))
            #expect(try Self.read(dir.appendingPathComponent(".zprofile")) == Self.line + "\n")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zprofile").path))
        }
        // A commented-out ZDOTDIR doesn't count.
        let home = try Self.home()
        try "# export ZDOTDIR=$HOME/.config/zsh\n".write(to: home.appendingPathComponent(".zshenv"), atomically: false,
                                                        encoding: .utf8)
        #expect(ShellPathEditor(home: home, shell: "/bin/zsh").offer == Self.appending(home, ".zprofile"))
    }

    @Test func unknownZdotdirOffersCopy() throws {
        let outside = try Self.home()
        let cases: [(String, String?)] = [
            // Missing directory under home: names the file, writes nothing.
            ("export ZDOTDIR=$HOME/.config/zsh", "~/.config/zsh/.zprofile"),
            // Outside the home folder.
            ("export ZDOTDIR=\(outside.path)", outside.path + "/.zprofile"),
            // A value BrewxPort can't work out without running a shell.
            ("export ZDOTDIR=$(brew --prefix)/zsh", nil),
            ("ZDOTDIR=$XDG_CONFIG_HOME/zsh", nil),
        ]
        for (assignment, hint) in cases {
            let home = try Self.home()
            try (assignment + "\n").write(to: home.appendingPathComponent(".zshenv"), atomically: false, encoding: .utf8)
            let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
            #expect(editor.offer == .copyOnly(hint: hint), "\(assignment)")
            #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: editor.offer) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == [".zshenv"])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // A directory under home that someone else owns.
        let home = try Self.home()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("zsh"), withIntermediateDirectories: false)
        try "ZDOTDIR=$HOME/zsh\n".write(to: home.appendingPathComponent(".zshenv"), atomically: false, encoding: .utf8)
        #expect(ShellPathEditor(home: home, shell: "/bin/zsh", owner: getuid() + 1).offer
                    == .copyOnly(hint: "~/zsh/.zprofile"))
    }

    @Test func zdotdirThatCannotBeParsedExactlyIsCopyOnly() throws {
        // Each would put the line somewhere other than where zsh reads it, so none falls back to ~/.zprofile.
        let cases = [
            #"export ZDOTDIR="$HOME"/.config/zsh"#,         // text after the closing quote
            "ZDOTDIR='HOMEDIR'/.config/zsh",
            #"ZDOTDIR="$HOME/.config/zsh"#,                  // no closing quote
            ##"ZDOTDIR="$HOME/.config/zsh"#x"##,            // `#` right after the quote isn't a comment
            #"ZDOTDIR=$HOME/"x y""#,                         // quotes inside an unquoted value
            #"ZDOTDIR=$HOME/.config/zs\h"#,                 // a backslash
            #"ZDOTDIR="$HOME/.config/z\sh""#,
            "ZDOTDIR=$HOME/.config/zsh zsh-extra",           // more words after the value
            "[ -d ~/.config/zsh ] && export ZDOTDIR=$HOME/.config/zsh",
            "typeset -x ZDOTDIR=$HOME/.config/zsh",
            ": ${ZDOTDIR:=$HOME/.config/zsh}",
            #"ZDOTDIR="~/.config/zsh""#,                    // zsh doesn't expand ~ inside quotes
            // A good assignment doesn't excuse an earlier one BrewxPort can't read.
            #"ZDOTDIR="$HOME"/x\nZDOTDIR=$HOME/.config/zsh"#,
        ]
        for assignment in cases {
            let home = try Self.home()
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/zsh"),
                                                    withIntermediateDirectories: true)
            let zshenv = assignment.replacingOccurrences(of: "HOMEDIR", with: home.path)
                .replacingOccurrences(of: "\\n", with: "\n") + "\n"
            try zshenv.write(to: home.appendingPathComponent(".zshenv"), atomically: false, encoding: .utf8)
            let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
            #expect(editor.offer == .copyOnly(hint: nil), "\(assignment)")
            #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: editor.offer) }
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zprofile").path))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/zsh/.zprofile").path))
        }
    }

    @Test func zshenvThatCannotBeReadIsCopyOnly() throws {
        // Not UTF-8, or not a regular file: it may set ZDOTDIR, so ~/.zprofile isn't offered either.
        let bytes = try Self.home()
        try Data([0x66, 0xFF, 0xFE, 0x0A]).write(to: bytes.appendingPathComponent(".zshenv"))
        let directory = try Self.home()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".zshenv"),
                                                withIntermediateDirectories: false)
        for home in [bytes, directory] {
            let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
            #expect(editor.offer == .copyOnly(hint: nil))
            #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: editor.offer) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == [".zshenv"])
        }
        // A symlinked .zshenv (a dotfile manager's) is still read.
        let linked = try Self.home()
        let real = linked.appendingPathComponent("dotfiles-zshenv")
        try "export EDITOR=vim\n".write(to: real, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".zshenv"),
                                                   withDestinationURL: real)
        #expect(ShellPathEditor(home: linked, shell: "/bin/zsh").offer == Self.appending(linked, ".zprofile"))
    }

    @Test func addWritesToTheFileTheOfferNamed() throws {
        // The offer was made before .zshenv set ZDOTDIR: the click still writes ~/.zprofile, the file it named.
        let home = try Self.home()
        let dir = home.appendingPathComponent(".config/zsh")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        let offer = editor.offer
        #expect(offer == Self.appending(home, ".zprofile"))
        try "export ZDOTDIR=$HOME/.config/zsh\n".write(to: home.appendingPathComponent(".zshenv"), atomically: false,
                                                       encoding: .utf8)
        #expect(editor.offer == Self.appending(home, ".config/zsh/.zprofile"))
        #expect(try editor.add(Self.bin, to: offer) == .added(file: "~/.zprofile"))
        #expect(try Self.read(home.appendingPathComponent(".zprofile")) == Self.line + "\n")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".zprofile").path))

        // And the other way round: offered ZDOTDIR's file, then .zshenv went away.
        let second = try Self.home()
        let zdot = second.appendingPathComponent(".config/zsh")
        try FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
        try "export ZDOTDIR=$HOME/.config/zsh\n".write(to: second.appendingPathComponent(".zshenv"),
                                                       atomically: false, encoding: .utf8)
        let other = ShellPathEditor(home: second, shell: "/bin/zsh")
        let zdotOffer = other.offer
        try FileManager.default.removeItem(at: second.appendingPathComponent(".zshenv"))
        #expect(try other.add(Self.bin, to: zdotOffer) == .added(file: "~/.config/zsh/.zprofile"))
        #expect(try Self.read(zdot.appendingPathComponent(".zprofile")) == Self.line + "\n")
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent(".zprofile").path))

        // A copy-only offer never writes, whatever the editor would offer now.
        #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: .copyOnly(hint: nil)) }
    }

    @Test func opensWithoutTakingATerminal() throws {
        #expect(ShellPathEditor.openFlags & O_NOCTTY != 0)
        #expect(ShellPathEditor.createFlags & O_NOCTTY != 0)
        #expect(ShellPathEditor.createFlags & O_NOFOLLOW != 0)
        // A ~/.zprofile that's a symlink to a terminal the person owns is refused, and nothing is written to it.
        // (Whether the open would have made it the controlling terminal can't be seen from a test process, which
        // isn't a session leader; O_NOCTTY above is what prevents it.)
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let terminal = String(cString: try #require(ptsname(master)))
        let home = try Self.home()
        let file = home.appendingPathComponent(".zprofile")
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: terminal)
        let editor = ShellPathEditor(home: home, shell: "/bin/zsh")
        #expect(throws: ShellPathEditor.Failure.notARegularFile(file: "~/.zprofile")) {
            try editor.add(Self.bin, to: editor.offer)
        }
    }

    @Test func otherShellOffersCopyOnly() throws {
        let home = try Self.home()
        for shell in ["/opt/homebrew/bin/fish", "/bin/sh", "/bin/ksh", nil] as [String?] {
            let editor = ShellPathEditor(home: home, shell: shell)
            #expect(editor.offer == .copyOnly(hint: nil))
            #expect(throws: ShellPathEditor.Failure.copyOnly) { try editor.add(Self.bin, to: editor.offer) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }
}
