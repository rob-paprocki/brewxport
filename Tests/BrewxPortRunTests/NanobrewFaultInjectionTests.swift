import Foundation
import Testing
import BrewxPortCore
@testable import BrewxPortRun

#if DEBUG
/// A folder tree the runner's closures act on: in memory, or a real temp directory standing in for `/`.
private final class FolderTree: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: PathInfo] = [:]
    private let realRoot: URL?
    private let uid: uid_t

    /// In memory.
    init(uid: uid_t) { realRoot = nil; self.uid = uid; entries["/opt"] = .directory(owner: 0, mode: 0o755) }

    /// Under a temp folder; the paths the runner uses are appended to it.
    init(realUnder root: URL, uid: uid_t) { realRoot = root; self.uid = uid }

    private func real(_ path: String) -> String { realRoot!.path + path }

    func info(_ path: String) -> PathInfo {
        if realRoot != nil {
            let found = PathInfo.lstat(real(path))
            // The temp folders belong to whoever runs the tests, but /opt is root's in the real tree.
            if path == EngineSetupRunner.opt, case .directory(_, let mode) = found {
                return .directory(owner: 0, mode: mode)
            }
            return found
        }
        return lock.withLock { entries[path] ?? .missing }
    }

    func make(_ path: String) -> Bool {
        if realRoot != nil { return mkdir(real(path), 0o755) == 0 }
        return lock.withLock {
            guard entries[path] == nil else { return false }
            entries[path] = .directory(owner: 0, mode: 0o755)
            return true
        }
    }

    func give(_ path: String, to owner: uid_t) -> Bool {
        if realRoot != nil { return PathInfo.lstat(real(path)) != .missing }
        return lock.withLock {
            guard case .directory(_, let mode)? = entries[path] else { return false }
            entries[path] = .directory(owner: owner, mode: mode)
            return true
        }
    }

    /// Only an empty directory goes.
    func remove(_ path: String) -> Bool {
        if realRoot != nil { return rmdir(real(path)) == 0 }
        return lock.withLock {
            guard entries[path] != nil, !entries.keys.contains(where: { $0.hasPrefix(path + "/") }) else { return false }
            entries[path] = nil
            return true
        }
    }

    /// `mkdir -p`, run as the requester.
    func makeAll(_ path: String) {
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            guard info(current) == .missing else { continue }
            if realRoot != nil {
                _ = mkdir(real(current), 0o755)
            } else {
                lock.withLock { entries[current] = .directory(owner: uid, mode: 0o755) }
            }
        }
    }

    func putBinary(_ path: String) {
        if realRoot != nil {
            FileManager.default.createFile(atPath: real(path), contents: Data("nb".utf8),
                                           attributes: [.posixPermissions: 0o755])
        } else {
            lock.withLock { entries[path] = .file(owner: uid, mode: 0o755) }
        }
    }

    var all: [String] { lock.withLock { entries.keys.sorted() } }
}

/// `EngineSetupRunner.failAfterNanobrewSteps` (a debug-only hook) fails nanobrew's folder preparation at each of its
/// six steps. After every one, the cleanup must leave nothing behind and a plain retry must finish the setup.
@Suite struct NanobrewFaultInjectionTests {
    /// Three mkdirs, then three hand-overs.
    static let steps = Array(1...6)

    /// A runner whose folder calls, and the sudo commands that touch folders, go to `tree`; the rest is `SetupWorld`'s.
    private static func runner(_ world: SetupWorld, _ tree: FolderTree, failAfter: Int?) -> EngineSetupRunner {
        var runner = world.runner()
        let fallback = runner.run
        runner.inspect = { tree.info($0) }
        runner.makeDirectory = { tree.make($0) }
        runner.giveDirectory = { tree.give($0, to: $1) }
        runner.removeDirectory = { tree.remove($0) }
        runner.run = { path, arguments in
            if path == "/usr/bin/sudo", arguments.count > 3 {
                switch arguments[2] {
                case "/bin/rmdir": return tree.remove(arguments[3]) ? (0, "") : (1, "not empty")
                case "/bin/mkdir" where arguments[3] == "-p": tree.makeAll(arguments[4]); return (0, "")
                case "/bin/mv": tree.putBinary(arguments[4]); return (0, "")
                default: break
                }
            }
            return await fallback(path, arguments)
        }
        runner.failAfterNanobrewSteps = failAfter
        return runner
    }

    private static func attempt(_ world: SetupWorld, _ tree: FolderTree, uid: uid_t,
                                failAfter: Int?) async -> SetupError? {
        do {
            try await runner(world, tree, failAfter: failAfter)
                .setUp(.nanobrew, forUID: uid, userName: "alice") { world.log($0) }
            return nil
        } catch {
            return error
        }
    }

    @Test(arguments: steps)
    func retryAfterFailureAtEveryStepSucceeds(failAfter: Int) async throws {
        let world = try SetupWorld()
        let tree = FolderTree(uid: 502)
        let first = await Self.attempt(world, tree, uid: 502, failAfter: failAfter)
        #expect(first == .installFailed("Injected failure after \(failAfter) nanobrew folder steps."))
        #expect(tree.all == ["/opt"], "left behind: \(tree.all)")
        #expect(!world.logs.contains { $0.contains("left") })
        #expect(await Self.attempt(world, tree, uid: 502, failAfter: nil) == nil)
        #expect(tree.info("/opt/nanobrew/prefix/bin/nb") == .file(owner: 502, mode: 0o755))
        #expect(tree.info("/opt/nanobrew") == .directory(owner: 502, mode: 0o755))
    }

    @Test func retryAfterFailureAtEveryStepSucceedsInARealTempFolder() async throws {
        let uid = getuid()
        for failAfter in Self.steps {
            let world = try SetupWorld()
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("nb-fault-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: base.appendingPathComponent("opt"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let tree = FolderTree(realUnder: base, uid: uid)
            let first = await Self.attempt(world, tree, uid: uid, failAfter: failAfter)
            #expect(first == .installFailed("Injected failure after \(failAfter) nanobrew folder steps."))
            #expect(!FileManager.default.fileExists(atPath: base.path + "/opt/nanobrew"), "step \(failAfter)")
            #expect(await Self.attempt(world, tree, uid: uid, failAfter: nil) == nil, "step \(failAfter)")
            #expect(FileManager.default.isExecutableFile(atPath: base.path + "/opt/nanobrew/prefix/bin/nb"))
        }
    }
}
#endif
