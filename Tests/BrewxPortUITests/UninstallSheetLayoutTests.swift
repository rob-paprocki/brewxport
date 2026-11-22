import Testing
import AppKit
import SwiftUI
import BrewxPortCore
@testable import BrewxPortUI

/// The sheet's height, measured the way AppKit sizes it. How it looks is checked in the VM.
@MainActor @Suite struct UninstallSheetLayoutTests {
    typealias S = UninstallScenario

    /// The ready sheet's fitting height for an uninstall of `count` Homebrew formulae.
    static func sheetHeight(picks count: Int) async throws -> CGFloat {
        let picks = (1...count).map { S.package(.homebrew, .formula, String(format: "tool%02d", $0), onRequest: true) }
        let s = S(homebrew: picks)
        for pick in picks { s.dependencies(.homebrew, .formula, pick.id.name, []) }
        await s.start(picks)
        let plan = try #require(await s.ready())
        #expect(plan.sections.first?.picks.count == count)
        return NSHostingView(rootView: UninstallSheet(model: s.model.uninstall)).fittingSize.height
    }

    @Test func fortyPicksStayUnderTheCap() async throws {
        // The list fills the cap and scrolls; the title and buttons stay outside it. Without the cap the sheet grows
        // with every pick.
        let height = try await Self.sheetHeight(picks: 40)
        let cap = UninstallSheet.listMaxHeight
        #expect(height > cap && height <= cap + 160, "height \(height)")
    }

    @Test func onePickSheetIsShort() async throws {
        // A short list is as tall as its contents: not stretched to the cap, not collapsed.
        let height = try await Self.sheetHeight(picks: 1)
        #expect(height > 80 && height < UninstallSheet.listMaxHeight, "height \(height)")
    }
}
