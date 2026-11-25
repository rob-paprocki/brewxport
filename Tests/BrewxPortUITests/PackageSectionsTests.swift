import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@Suite struct PackageSectionsTests {
    struct Item: Identifiable, Equatable {
        let id: String
        let engine: EngineID
    }

    static let order: [EngineID] = [.homebrew, .nanobrew, .macports, .mas]

    static func sections(_ items: [Item], order: [EngineID] = order) -> [PackageSection<Item>] {
        PackageSections.make(items, engine: { $0.engine }, order: order)
    }

    @Test func sectionsFollowEngineOrder() {
        let items = [Item(id: "a", engine: .mas), Item(id: "b", engine: .homebrew), Item(id: "c", engine: .macports)]
        let result = Self.sections(items)
        #expect(result.map(\.engine) == [.homebrew, .macports, .mas])
        #expect(result.map(\.id) == [.homebrew, .macports, .mas])
    }

    @Test func rowsKeepTheirOrderWithinASection() {
        let items = [
            Item(id: "z", engine: .homebrew), Item(id: "m", engine: .macports),
            Item(id: "a", engine: .homebrew), Item(id: "k", engine: .homebrew),
        ]
        let result = Self.sections(items)
        #expect(result[0].rows.map(\.id) == ["z", "a", "k"])
        #expect(result[1].rows.map(\.id) == ["m"])
    }

    @Test func emptySectionRemoved() {
        let result = Self.sections([Item(id: "a", engine: .nanobrew)])
        #expect(result.map(\.engine) == [.nanobrew])
        #expect(Self.sections([]).isEmpty)
    }

    @Test func unknownEngineLast() {
        let items = [
            Item(id: "a", engine: .mas), Item(id: "b", engine: .nanobrew),
            Item(id: "c", engine: .macports), Item(id: "d", engine: .homebrew),
        ]
        let result = Self.sections(items, order: [.homebrew])
        #expect(result.map(\.engine) == [.homebrew, .mas, .nanobrew, .macports])
    }
}
