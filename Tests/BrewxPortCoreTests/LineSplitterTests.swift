import Foundation
import Synchronization
import Testing
@testable import BrewxPortCore

/// Collects what a LineSplitter emits.
private final class Lines: Sendable {
    private let state = Mutex<[String]>([])
    var all: [String] { state.withLock { $0 } }
    func append(_ line: String) { state.withLock { $0.append(line) } }
}

@Suite struct LineSplitterTests {
    private func split(_ chunks: [Data], max: Int = LineSplitter.maxLineBytes) -> [String] {
        let lines = Lines()
        let splitter = LineSplitter(maxLineBytes: max) { lines.append($0) }
        for chunk in chunks { splitter.feed(chunk) }
        splitter.flush()
        return lines.all
    }

    private func bytes(_ count: Int, _ byte: UInt8 = UInt8(ascii: "a")) -> Data {
        Data(repeating: byte, count: count)
    }

    @Test func capIs64KiB() {
        #expect(LineSplitter.maxLineBytes == 65_536)
    }

    @Test func lineOfExactlyTheCapIsOneLine() {
        let lines = split([bytes(65_536) + Data("\n".utf8)])
        #expect(lines.map(\.utf8.count) == [65_536])
    }

    @Test func oneByteOverTheCapIsTwoLines() {
        let lines = split([bytes(65_537) + Data("\nnext\n".utf8)])
        #expect(lines.map(\.utf8.count) == [65_536, 1, 4])
        #expect(lines.last == "next")
    }

    @Test func unterminatedOutputIsEmittedAsItGrows() {
        // 200 KiB with no newline, fed 1000 bytes at a time: pieces come out before flush, none over the cap.
        let emitted = Lines()
        let splitter = LineSplitter { emitted.append($0) }
        for _ in 0..<205 { splitter.feed(bytes(1000)) }
        #expect(emitted.all.map(\.utf8.count) == [65_536, 65_536, 65_536])
        splitter.flush()
        #expect(emitted.all.map(\.utf8.count) == [65_536, 65_536, 65_536, 205_000 - 3 * 65_536])
    }

    @Test func multibyteCharacterIsNeverCut() {
        // "é" is 2 bytes and "😀" 4. With a cap of 8, "abcdefg" + "é" would cut the é in half at byte 8.
        let text = "abcdefgé" + "abcde😀x"
        let lines = split([Data(text.utf8)], max: 8)
        #expect(lines == ["abcdefg", "éabcde", "😀x"])
        #expect(lines.joined() == text)
        #expect(lines.allSatisfy { $0.utf8.count <= 8 })
        #expect(!lines.joined().contains("\u{FFFD}"))
    }

    @Test func shortLinesAreUnchanged() {
        #expect(split([Data("one\ntw".utf8), Data("o\nthree".utf8)]) == ["one", "two", "three"])
    }
}
