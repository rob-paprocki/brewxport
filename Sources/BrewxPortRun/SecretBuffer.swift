import Foundation
import os

private let secretLog = Logger(subsystem: "com.brewxport", category: "secret")

/// Logs an `mlock` failure once per process. A failure isn't fatal: the bytes are still wiped.
private let mlockWarning = OSAllocatedUnfairLock(initialState: false)

/// The run's admin password. It lives in one heap allocation that is locked into RAM (so it isn't paged out),
/// zeroed with `memset_s` (which the compiler may not drop) by `wipe()` and again before it's freed.
///
/// The bytes stay allocated until deinit, so `withBytes` after `wipe()` sees zeros of the original length and
/// never freed memory. All access is under one lock; `body` must not call back into the same buffer.
public final class SecretBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: UnsafeMutableRawPointer
    private let count: Int
    private let capacity: Int
    private let locked: Bool
    private var wiped = false

    /// Test hook: called with the zeroed bytes after each real wipe (once), before anything is freed.
    var wipeObserver: (@Sendable (UnsafeRawBufferPointer) -> Void)? {
        get { lock.withLock { _wipeObserver } }
        set { lock.withLock { _wipeObserver = newValue } }
    }
    private var _wipeObserver: (@Sendable (UnsafeRawBufferPointer) -> Void)?

    public init(copying bytes: some Collection<UInt8>) {
        count = bytes.count
        capacity = max(count, 1)  // malloc(0) may return nil
        guard let memory = malloc(capacity) else { fatalError("SecretBuffer: out of memory") }
        storage = memory
        let destination = UnsafeMutableRawBufferPointer(start: storage, count: capacity)
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
        if mlock(storage, capacity) == 0 {
            locked = true
        } else {
            locked = false
            let err = errno
            let first = mlockWarning.withLock { warned in
                defer { warned = true }
                return !warned
            }
            if first { secretLog.error("mlock failed (errno \(err)); the secret may be paged out") }
        }
    }

    deinit {
        wipe()
        if locked { munlock(storage, capacity) }
        free(storage)
    }

    /// Runs `body` with the secret's bytes. After `wipe()` they are all zeros, of the original length.
    /// Don't copy them into a `String` or keep the pointer.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(UnsafeRawBufferPointer(start: storage, count: count))
    }

    /// Like `withBytes`, but returns nil without calling `body` once the buffer is wiped. The check and the read
    /// happen under one lock, so a concurrent `wipe()` can't hand `body` zeros.
    func withUnwipedBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { return nil }
        return try body(UnsafeRawBufferPointer(start: storage, count: count))
    }

    /// Zeroes the bytes. Idempotent; deinit calls it.
    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { return }
        _ = memset_s(storage, capacity, 0, capacity)
        wiped = true
        _wipeObserver?(UnsafeRawBufferPointer(start: storage, count: count))
    }

    public var isWiped: Bool { lock.withLock { wiped } }
}
