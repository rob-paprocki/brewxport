import Testing
import Foundation
@testable import BrewxPortRun

/// Collects what a wipe observer saw. The observer runs on whatever thread wipes, so it's locked.
final class WipeRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [[UInt8]] = []
    var seen: [[UInt8]] { lock.withLock { _seen } }
    func record(_ bytes: UnsafeRawBufferPointer) { lock.withLock { _seen.append(Array(bytes)) } }
}

@Suite struct SecretBufferTests {
    @Test func holdsTheBytesItWasGiven() {
        let secret = SecretBuffer(copying: Array("hunter2".utf8))
        #expect(!secret.isWiped)
        secret.withBytes { #expect(Array($0) == Array("hunter2".utf8)) }
    }

    @Test func wipeZeroes() {
        let secret = SecretBuffer(copying: Array("correct horse".utf8))
        secret.wipe()
        #expect(secret.isWiped)
        secret.withBytes { bytes in
            #expect(bytes.count == "correct horse".utf8.count)
            #expect(bytes.allSatisfy { $0 == 0 })
        }
        secret.wipe()  // idempotent
        #expect(secret.isWiped)
        secret.withBytes { #expect($0.allSatisfy { $0 == 0 }) }
    }

    @Test func emptySecretIsAllowed() {
        let secret = SecretBuffer(copying: [UInt8]())
        secret.withBytes { #expect($0.count == 0) }
        secret.wipe()
        #expect(secret.isWiped)
    }

    /// Weak check: deinit runs the wipe and hands the observer the buffer before it's freed.
    @Test func deinitWipes() {
        let record = WipeRecord()
        do {
            let secret = SecretBuffer(copying: Array("s3cret!".utf8))
            secret.wipeObserver = { record.record($0) }
            #expect(record.seen.isEmpty)
            _ = secret
        }
        #expect(record.seen.count == 1)
        #expect(record.seen.first == [UInt8](repeating: 0, count: 7))
    }

    @Test func explicitWipeThenDeinitWipesOnce() {
        let record = WipeRecord()
        do {
            let secret = SecretBuffer(copying: Array("abc".utf8))
            secret.wipeObserver = { record.record($0) }
            secret.wipe()
            #expect(record.seen.count == 1)
        }
        #expect(record.seen.count == 1)
    }

    @Test func concurrentReadsAndWipeDontRace() async {
        let secret = SecretBuffer(copying: [UInt8](repeating: 0x41, count: 64))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask {
                    if i == 32 { secret.wipe() }
                    secret.withBytes { bytes in
                        // Either all original or all zero; never torn.
                        let first = bytes.first
                        #expect(bytes.allSatisfy { $0 == first })
                    }
                }
            }
        }
        #expect(secret.isWiped)
    }
}
