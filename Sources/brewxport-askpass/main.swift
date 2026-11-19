// brewxport-askpass: sudo's SUDO_ASKPASS helper for a BrewxPort run.
//
// sudo runs it with the prompt as argv[1], which is ignored. It finds BrewxPort's askpass socket and the run's nonce in
// HOMEBREW_BREWXPORT_ASKPASS_SOCKET and HOMEBREW_BREWXPORT_ASKPASS_NONCE (brew passes only HOMEBREW_* variables through),
// sends `nonce\n` and prints what comes back plus a newline. On any refusal or error it prints nothing and exits 1,
// so sudo gives up at once. The server identifies this process and its parent (sudo) through the kernel, so
// nothing else is sent. Darwin only, no Foundation: the fewer copies of the password, the better.
import Darwin

let passwordLimit = 4096
let timeoutSeconds = 5

func fail() -> Never { exit(1) }

guard let socketValue = getenv("HOMEBREW_BREWXPORT_ASKPASS_SOCKET"),
      let nonceValue = getenv("HOMEBREW_BREWXPORT_ASKPASS_NONCE")
else { fail() }
let socketPath = Array(String(cString: socketValue).utf8)
let nonce = Array(String(cString: nonceValue).utf8)
guard socketPath.first == UInt8(ascii: "/"), nonce.count == 64 else { fail() }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail() }
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
guard socketPath.count < MemoryLayout.size(ofValue: address.sun_path) else { fail() }
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (i, byte) in socketPath.enumerated() { raw[i] = byte }
}
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail() }

func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return false }
        offset += n
    }
    return true
}

let request = nonce + [0x0A]
guard request.withUnsafeBytes({ writeAll(fd, $0) }) else { fail() }

// The password goes into this one buffer, out to stdout, and is zeroed before exit.
var buffer = [UInt8](repeating: 0, count: passwordLimit + 1)
let ok: Bool = buffer.withUnsafeMutableBytes { raw in
    defer { _ = memset_s(raw.baseAddress, raw.count, 0, raw.count) }
    var length = 0
    while length < raw.count {
        let n = read(fd, raw.baseAddress! + length, raw.count - length)
        if n < 0, errno == EINTR { continue }
        if n < 0 { return false }  // timeout or error: refuse
        if n == 0 { break }
        length += n
    }
    // Nothing back is a refusal; more than the limit isn't a password.
    guard length > 0, length <= passwordLimit else { return false }
    raw[length] = 0x0A
    return writeAll(STDOUT_FILENO, UnsafeRawBufferPointer(rebasing: raw[0...length]))
}
close(fd)
exit(ok ? 0 : 1)
