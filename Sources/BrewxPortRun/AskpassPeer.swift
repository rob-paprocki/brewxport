import Darwin
import Foundation
import Security

/// Returns the kernel's view of the process on the other end of an accepted askpass connection, or nil when it
/// can't be established. Injectable so tests can drive the server with a fake identity.
typealias AskpassPeerInspector = @Sendable (Int32) -> AskpassPeer?

/// The kernel's parent pid for a pid, or nil when it can't be read. Injectable so tests can describe a process
/// tree.
typealias AskpassParentLookup = @Sendable (pid_t) -> pid_t?

/// Whether the process on the other end of a client socket satisfies a code-signing requirement. Injectable so
/// tests can count calls; production and the tests' real-check cases use `AskpassPeer.satisfies`.
typealias AskpassCodeCheck = @Sendable (_ socket: Int32, _ requirement: SecRequirement) -> Bool

/// Who is asking for the password, from the kernel rather than from anything the client says.
struct AskpassPeer: Sendable, Equatable {
    var uid: uid_t
    var pid: pid_t
    /// The peer's executable, from `proc_pidpath_audittoken`.
    var path: String
    /// The peer's real parent, from `proc_pidinfo(PROC_PIDT_SHORTBSDINFO).pbsi_ppid`.
    var parentPID: pid_t
    var parentPath: String

    /// The only parent that may receive the password: sudo running `SUDO_ASKPASS`.
    static let sudoPath = "/usr/bin/sudo"

    /// The production inspector.
    ///
    /// The peer is named by its audit token (`LOCAL_PEERTOKEN`), which carries the pid version, so
    /// `proc_pidpath_audittoken` fails rather than describe a different process that reused the pid. The parent is
    /// read by pid, then the peer's token and parent are checked again: if the peer exited, or was reparented
    /// because its sudo exited, between the reads, the answer is nil.
    @Sendable static func inspect(_ socket: Int32) -> AskpassPeer? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              Int(length) == MemoryLayout<audit_token_t>.size
        else { return nil }
        // audit_token_t.val: [5] is the pid, [1] the effective uid (see audit_token_to_pid in libbsm).
        let pid = pid_t(bitPattern: token.val.5)
        let uid = uid_t(token.val.1)

        var socketPID: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &socketPID, &pidLength) == 0, socketPID == pid, pid > 0
        else { return nil }

        guard let path = executablePath(of: &token), let parent = parentPID(of: pid), parent > 1,
              let parentPath = executablePath(of: parent),
              // Still the same process, still the child of that parent.
              executablePath(of: &token) == path, parentPID(of: pid) == parent
        else { return nil }
        return AskpassPeer(uid: uid, pid: pid, path: path, parentPID: parent, parentPath: parentPath)
    }

    /// The production `AskpassCodeCheck` (ruling R17). It names the peer by its audit token (`LOCAL_PEERTOKEN`),
    /// which carries the pid version, so a process that exited and had its pid reused is never the one checked.
    /// `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributeAudit` gets that process's code, and
    /// `SecCodeCheckValidity` checks its dynamic signature (still valid in memory) against `requirement`.
    /// Any failure is a refusal.
    @Sendable static func satisfies(_ socket: Int32, _ requirement: SecRequirement) -> Bool {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              Int(length) == MemoryLayout<audit_token_t>.size
        else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func string(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `realpath`, or nil when the path doesn't resolve.
    static func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static let pathBufferSize = 4 * Int(MAXPATHLEN)  // PROC_PIDPATHINFO_MAXSIZE

    private static func executablePath(of token: inout audit_token_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath_audittoken(&token, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return string(buffer)
    }

    /// How many parents `chainReaches` follows. BrewxPort -> brew -> ruby -> sudo is three; 32 leaves room for
    /// shells and build tools while bounding the walk.
    static let maxAncestorDepth = 32

    /// True when `target` is `start` or one of its ancestors within `maxAncestorDepth` hops. Stops at pid 1
    /// (launchd), at a pid whose parent can't be read, and on a repeated pid.
    static func chainReaches(_ target: pid_t, from start: pid_t, parentOf: AskpassParentLookup) -> Bool {
        var pid = start
        var seen = Set<pid_t>()
        for _ in 0...maxAncestorDepth {
            if pid == target { return true }
            guard pid > 1, seen.insert(pid).inserted, let parent = parentOf(pid) else { return false }
            pid = parent
        }
        return false
    }

    /// The production `AskpassParentLookup`: `proc_pidinfo(PROC_PIDT_SHORTBSDINFO).pbsi_ppid`. The short flavor
    /// is readable across users; `PROC_PIDTBSDINFO` refuses (EPERM) a root process such as sudo.
    @Sendable static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(bitPattern: info.pbsi_ppid)
    }
}
