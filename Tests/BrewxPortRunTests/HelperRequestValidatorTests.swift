import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortRun

private func expectNotAllowed(_ arguments: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try HelperRequestValidator.validate(arguments: arguments)
        Issue.record("expected \(arguments) to be refused", sourceLocation: sourceLocation)
    } catch let e as HelperError {
        guard case .notAllowed = e else {
            Issue.record("wrong case \(e) for \(arguments)", sourceLocation: sourceLocation); return
        }
    } catch {
        Issue.record("wrong error \(error) for \(arguments)", sourceLocation: sourceLocation)
    }
}

@Suite struct HelperRequestValidatorTests {
    // MARK: argv

    @Test func allowsPortInstall() throws {
        try HelperRequestValidator.validate(arguments: ["-N", "install", "figlet"])
        try HelperRequestValidator.validate(arguments: ["-N", "install", "-s", "-b", "gtk3", "+universal", "-x11"])
        try HelperRequestValidator.validate(arguments: ["-N", "install", "py313-numpy", "p5.38-libwww-perl", "gtk+3"])
    }

    @Test func allowsOtherVerbs() throws {
        try HelperRequestValidator.validate(arguments: ["-N", "upgrade", "a", "b"])
        try HelperRequestValidator.validate(arguments: ["-N", "upgrade", "-u", "-R", "a"])
        try HelperRequestValidator.validate(arguments: ["-N", "uninstall", "a"])
        try HelperRequestValidator.validate(arguments: ["-N", "selfupdate"])
        try HelperRequestValidator.validate(arguments: ["-N", "selfupdate", "-c"])
    }

    @Test func setrequestedAllowed() throws {
        try HelperRequestValidator.validate(arguments: ["-N", "setrequested", "wget"])
        try HelperRequestValidator.validate(arguments: ["-N", "setrequested", "a", "b"])
    }

    @Test func unsetrequestedAllowed() throws {
        try HelperRequestValidator.validate(arguments: ["-N", "unsetrequested", "wget"])
    }

    @Test func setrequestedRefusesVariant() {
        expectNotAllowed(["-N", "setrequested", "wget", "+ssl"])
        expectNotAllowed(["-N", "unsetrequested", "wget", "+ssl"])
    }

    @Test func setrequestedRefusesNoName() {
        expectNotAllowed(["-N", "setrequested"])
        expectNotAllowed(["-N", "unsetrequested"])
    }

    @Test func setrequestedRefusesFlags() {
        expectNotAllowed(["-N", "setrequested", "-s", "wget"])
    }

    @Test func rejectsUnknownVerb() {
        for verb in ["sync", "load", "unload", "activate", "deactivate", "clean", "-f", "", "Install", "INSTALL",
                     "install ", "shell", "edit"] {
            expectNotAllowed(["-N", verb, "figlet"])
        }
        #expect(throws: HelperError.notAllowed("load")) {
            try HelperRequestValidator.validate(arguments: ["-N", "load", "figlet"])
        }
    }

    @Test func rejectsMissingDashN() {
        expectNotAllowed(["install", "figlet"])
        expectNotAllowed(["-n", "install", "figlet"])
        expectNotAllowed(["-s", "-N", "install", "figlet"])
        expectNotAllowed(["-N"])
        expectNotAllowed([])
    }

    @Test func rejectsPseudoPortName() {
        for pseudo in ["outdated", "installed", "all", "active", "inactive", "actinact", "leaves", "requested",
                       "Outdated", "and", "or", "not", "name:fig", "fig*", "fig?", "[a-z]*", "./figlet",
                       "/tmp/x", "file:///tmp/x", "variants:x11", "depof:figlet"] {
            expectNotAllowed(["-N", "uninstall", pseudo])
            expectNotAllowed(["-N", "install", "figlet", pseudo])
        }
        #expect(throws: HelperError.notAllowed("outdated")) {
            try HelperRequestValidator.validate(arguments: ["-N", "upgrade", "outdated"])
        }
    }

    @Test func rejectsDisallowedExtraArg() {
        for flag in ["-f", "--force", "-d", "-D", "-F", "-sb", "-p", "-q", "-v", "-y", "-o", "-t", "-x"] {
            expectNotAllowed(["-N", "install", flag, "figlet"])
            expectNotAllowed(["-N", "selfupdate", flag])
        }
        // Allowed flags only directly after the verb, the way MacPortsEngine lays them out.
        expectNotAllowed(["-N", "install", "figlet", "-s"])
        expectNotAllowed(["-N", "upgrade", "a", "-u", "b"])
        expectNotAllowed(["-N", "-s", "install", "figlet"])
    }

    @Test func variantsOnlyForInstallAndOnlyAfterNames() {
        expectNotAllowed(["-N", "upgrade", "gtk3", "+universal"])
        expectNotAllowed(["-N", "uninstall", "gtk3", "+universal"])
        expectNotAllowed(["-N", "selfupdate", "+universal"])
        expectNotAllowed(["-N", "install", "+universal", "gtk3"])
        expectNotAllowed(["-N", "install", "+universal"])
        expectNotAllowed(["-N", "install", "gtk3", "+universal", "cairo"])
        expectNotAllowed(["-N", "install", "gtk3", "+x"])          // one letter reads as a flag
        expectNotAllowed(["-N", "install", "gtk3", "+a=b"])
    }

    @Test func requiresNamesExceptForSelfupdate() {
        for verb in ["install", "upgrade", "uninstall"] {
            expectNotAllowed(["-N", verb])
            expectNotAllowed(["-N", verb, "-s"])
        }
        expectNotAllowed(["-N", "selfupdate", "figlet"])
    }

    @Test func rejectsEmptyNulAndOverlongTokens() {
        expectNotAllowed(["-N", "install", ""])
        expectNotAllowed(["-N", "install", "fig\0let"])
        expectNotAllowed(["-N", "install", "figlet\0"])
        expectNotAllowed(["-N\0", "install", "figlet"])
        let long = String(repeating: "a", count: HelperRequestValidator.maxTokenBytes + 1)
        expectNotAllowed(["-N", "install", long])
        #expect(throws: Never.self) {
            try HelperRequestValidator.validate(
                arguments: ["-N", "install", String(repeating: "a", count: HelperRequestValidator.maxTokenBytes)])
        }
        let many = ["-N", "install"] + (0..<HelperRequestValidator.maxArguments - 1).map { "p\($0)" }
        #expect(many.count == HelperRequestValidator.maxArguments + 1)
        expectNotAllowed(many)
        #expect(throws: Never.self) {
            try HelperRequestValidator.validate(arguments: Array(many.dropLast()))
        }
        expectNotAllowed(["-N", "install", "fïglet"])
        expectNotAllowed(["-N", "install", "figlet\n-f"])
    }

    @Test func acceptsEveryCommandMacPortsEngineBuilds() throws {
        let engine = MacPortsEngine(runner: NeverRunner(), executable: URL(fileURLWithPath: HelperRequestValidator.portPath))
        func ref(_ n: String) -> PackageRef { PackageRef(engine: .macports, kind: .port, name: n) }
        let specs = [
            try engine.command(for: .install, [ref("figlet")], options: InstallOptions()),
            try engine.command(for: .install, [ref("a"), ref("b")], options: InstallOptions(extraArgs: ["-s", "-n"])),
            try engine.command(for: .install, [ref("gtk3")],
                               options: InstallOptions(variants: ["+universal", "-x11"], extraArgs: ["-b", "-c"])),
            try engine.command(for: .upgrade, [ref("a"), ref("b")], options: InstallOptions(extraArgs: ["-R", "-u"])),
            try engine.command(for: .remove, [ref("a")], options: InstallOptions()),
        ]
        for spec in specs {
            #expect(spec.executable.path == HelperRequestValidator.portPath)
            try HelperRequestValidator.validate(arguments: spec.arguments)
        }
    }

    // MARK: executable

    private static func dir(owner: Int = 0, mode: Int = 0o755) -> [FileAttributeKey: Any] {
        [.type: FileAttributeType.typeDirectory, .ownerAccountID: NSNumber(value: owner),
         .posixPermissions: NSNumber(value: mode)]
    }
    private static func file(owner: Int = 0, mode: Int = 0o755,
                             type: FileAttributeType = .typeRegular) -> [FileAttributeKey: Any] {
        [.type: type, .ownerAccountID: NSNumber(value: owner), .posixPermissions: NSNumber(value: mode)]
    }

    /// A healthy MacPorts tree; `overrides` replaces single paths.
    private static func fs(_ overrides: [String: [FileAttributeKey: Any]] = [:])
        -> @Sendable (String) throws -> [FileAttributeKey: Any] {
        var table: [String: [FileAttributeKey: Any]] = [
            "/": dir(mode: 0o755), "/opt": dir(), "/opt/local": dir(), "/opt/local/bin": dir(),
            "/opt/local/bin/port": file(),
            "/opt/local/libexec": dir(), "/opt/local/libexec/macports": dir(),
            "/opt/local/libexec/macports/bin": dir(),
            "/opt/local/libexec/macports/bin/tclsh8.6": file(),
        ]
        for (k, v) in overrides { table[k] = v }
        let frozen = UncheckedBox(table)
        return { path in
            guard let a = frozen.value[path] else { throw CocoaError(.fileNoSuchFile) }
            return a
        }
    }

    private func expectBadExecutable(_ attrs: @Sendable (String) throws -> [FileAttributeKey: Any],
                                     path: String = HelperRequestValidator.portPath,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            try HelperRequestValidator.validateExecutable(atPath: path, attributes: attrs)
            Issue.record("expected \(path) to be refused", sourceLocation: sourceLocation)
        } catch let e as HelperError {
            guard case .badExecutable = e else { Issue.record("wrong case \(e)", sourceLocation: sourceLocation); return }
        } catch { Issue.record("wrong error \(error)", sourceLocation: sourceLocation) }
    }

    @Test func acceptsRootOwnedExecutable() throws {
        try HelperRequestValidator.validateExecutable(atPath: HelperRequestValidator.portPath, attributes: Self.fs())
        // Group admin (80) with no group write is fine; only the owner matters.
        try HelperRequestValidator.validateExecutable(
            atPath: HelperRequestValidator.portPath,
            attributes: Self.fs(["/opt/local/bin/port": Self.file(mode: 0o555)]))
    }

    @Test func refusesNonRootOwnedExecutable() {
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(owner: 501)]))
        #expect(throws: HelperError.badExecutable("/opt/local/bin/port is owned by uid 501, not root")) {
            try HelperRequestValidator.validateExecutable(
                atPath: HelperRequestValidator.portPath,
                attributes: Self.fs(["/opt/local/bin/port": Self.file(owner: 501)]))
        }
    }

    @Test func refusesGroupWritable() {
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(mode: 0o775)]))
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(mode: 0o757)]))
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(mode: 0o777)]))
    }

    @Test func refusesUnsafeAncestorDirectory() {
        for d in ["/", "/opt", "/opt/local", "/opt/local/bin"] {
            expectBadExecutable(Self.fs([d: Self.dir(owner: 501)]))
            expectBadExecutable(Self.fs([d: Self.dir(mode: 0o775)]))
            expectBadExecutable(Self.fs([d: Self.dir(mode: 0o1777)]))
            expectBadExecutable(Self.fs([d: Self.file(type: .typeSymbolicLink)]))
            expectBadExecutable(Self.fs([d: Self.file()]))  // not a directory
        }
    }

    @Test func refusesSymlinkOrNonRegularExecutable() {
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(type: .typeSymbolicLink)]))
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(type: .typeDirectory)]))
        expectBadExecutable(Self.fs(["/opt/local/bin/port": Self.file(type: .typeSocket)]))
    }

    @Test func refusesMissingOrIncompleteAttributes() {
        expectBadExecutable({ _ in throw CocoaError(.fileNoSuchFile) })
        expectBadExecutable(Self.fs(["/opt/local/bin/port": [.type: FileAttributeType.typeRegular]]))
        expectBadExecutable(Self.fs(["/opt/local/bin/port": [.ownerAccountID: NSNumber(value: 0),
                                                              .posixPermissions: NSNumber(value: 0o755)]]))
    }

    @Test func refusesNonCanonicalPath() {
        for p in ["opt/local/bin/port", "/opt/local/bin/../bin/port", "/opt/./local/bin/port",
                  "/opt//local/bin/port", "/opt/local/bin/port/", ""] {
            expectBadExecutable(Self.fs(), path: p)
        }
    }

    // MARK: the production adapters on the real disk (read-only, except a symlink in a temp dir)

    @Test func realAttributesPassForASystemBinary() throws {
        try HelperRequestValidator.validateExecutable(atPath: "/bin/ls",
                                                      attributes: HelperRequestValidator.fileSystemAttributes)
    }

    @Test func realAttributesDoNotFollowSymlinks() {
        // /tmp is a symbolic link to /private/tmp on macOS.
        #expect(throws: HelperError.badExecutable("/tmp is a symbolic link")) {
            try HelperRequestValidator.validateExecutable(atPath: "/tmp/brewxport-x",
                                                          attributes: HelperRequestValidator.fileSystemAttributes)
        }
    }

    @Test func realAttributesRefuseAUserOwnedTree() {
        expectBadExecutable(HelperRequestValidator.fileSystemAttributes, path: #filePath)
    }

    @Test func readScriptHeadRefusesASymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-head-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("script")
        try Data("#!/bin/sh\necho\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try HelperRequestValidator.readScriptHead(target.path) == Data("#!/bin/sh\necho\n".utf8))
        #expect(throws: (any Error).self) { _ = try HelperRequestValidator.readScriptHead(link.path) }
    }

    // MARK: interpreter (port is a tclsh script)

    @Test func readsInterpreterFromShebang() throws {
        let head = Data("#!/opt/local/libexec/macports/bin/tclsh8.6\n# -*- coding: utf-8\n".utf8)
        #expect(try HelperRequestValidator.interpreterPath(scriptHead: head) == "/opt/local/libexec/macports/bin/tclsh8.6")
        #expect(try HelperRequestValidator.interpreterPath(scriptHead: Data("#! /opt/local/libexec/macports/bin/tclsh8.6 \n".utf8))
                == "/opt/local/libexec/macports/bin/tclsh8.6")
    }

    @Test func refusesInterpreterOutsideMacPortsPrefix() {
        for head in ["#!/usr/bin/env tclsh\n", "#!/tmp/tclsh\n", "#!/opt/local/bin/tclsh\n",
                     "#!/opt/local/libexec/macports/bin/../../../../tmp/x\n", "no shebang\n", "", "#!\n",
                     "#!/opt/local/libexec/macports/bin/tclsh8.6"] {  // no newline: may be truncated
            #expect(throws: HelperError.self) {
                _ = try HelperRequestValidator.interpreterPath(scriptHead: Data(head.utf8))
            }
        }
    }

    @Test func validatesPortAndItsInterpreter() throws {
        let head: @Sendable (String) throws -> Data = { _ in Data("#!/opt/local/libexec/macports/bin/tclsh8.6\n".utf8) }
        try HelperRequestValidator.validateInstallation(attributes: Self.fs(), readHead: head)
        #expect(throws: HelperError.self) {
            try HelperRequestValidator.validateInstallation(
                attributes: Self.fs(["/opt/local/libexec/macports/bin/tclsh8.6": Self.file(owner: 501)]), readHead: head)
        }
        #expect(throws: HelperError.self) {
            try HelperRequestValidator.validateInstallation(
                attributes: Self.fs(["/opt/local/libexec/macports": Self.dir(mode: 0o777)]), readHead: head)
        }
        #expect(throws: HelperError.self) {
            try HelperRequestValidator.validateInstallation(
                attributes: Self.fs(["/opt/local/bin/port": Self.file(owner: 501)]), readHead: head)
        }
        #expect(throws: HelperError.self) {
            try HelperRequestValidator.validateInstallation(
                attributes: Self.fs(), readHead: { _ in throw CocoaError(.fileReadNoPermission) })
        }
    }

    // MARK: compatibility

    @Test func versionMismatchIsReported() {
        #expect(HelperCompatibility.check(installed: brewxPortHelperVersion, bundled: brewxPortHelperVersion))
        #expect(!HelperCompatibility.check(installed: 1, bundled: 2))
        #expect(!HelperCompatibility.check(installed: 2, bundled: 1))
        #expect(brewxPortHelperVersion == 2)
    }
}

/// Lets a test hand a fixed, never-mutated table to a `@Sendable` closure.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// `MacPortsEngine.command(for:)` never runs anything.
private struct NeverRunner: CommandRunning {
    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        Issue.record("unexpected run"); return CommandResult(exitCode: 1, stdout: "", stderr: "")
    }
    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        Issue.record("unexpected stream"); return 1
    }
}
