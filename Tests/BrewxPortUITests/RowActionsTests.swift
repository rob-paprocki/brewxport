import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor
struct RowActionsTests {
    private func ref(_ name: String, engine: EngineID = .homebrew, kind: PackageKind = .formula) -> PackageRef {
        PackageRef(engine: engine, kind: kind, name: name)
    }

    private func row(_ name: String, installed: String? = nil, latest: String? = nil,
                     engine: EngineID = .homebrew, kind: PackageKind = .formula, display: String? = nil) -> PackageRow {
        PackageRow(package: Package(id: ref(name, engine: engine, kind: kind), displayName: display ?? name,
                                    installedVersion: installed, latestVersion: latest), arch: .arm64)
    }

    private func table(_ rows: PackageRow...) -> [PackageRef: PackageRow] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    private func items(_ refs: Set<PackageRef>, _ view: PackageView, _ rows: [PackageRef: PackageRow],
                       outdated: Set<PackageRef> = [], prefs: UpdatePreferences? = nil,
                       isRunning: Bool = false, canRun: Bool = true) -> [RowActionItem] {
        RowActions.items(for: refs, in: view, rows: rows, outdated: outdated,
                         prefs: prefs ?? UpdatePreferences(store: MemoryStore()), isRunning: isRunning, canRun: canRun)
    }

    @Test func discoverMenuForUninstalledRow() {
        let rows = table(row("wget"))
        let menu = items([ref("wget")], .discover, rows)
        #expect(menu.map(\.title) == ["Install", "Show details", "Copy name"])
        #expect(menu.map(\.systemImage) == ["arrow.down.circle", "info.circle", "doc.on.doc"])
        #expect(menu.map(\.action) == [.install, .showDetails, .copyName])
    }

    @Test func discoverMenuHidesInstallWhenAllInstalled() {
        let rows = table(row("wget", installed: "1.0"), row("jq", installed: "1.7"))
        let menu = items([ref("wget"), ref("jq")], .discover, rows)
        #expect(menu.map(\.title) == ["Copy names"])
        let mixed = table(row("wget", installed: "1.0"), row("jq"))
        #expect(items([ref("wget"), ref("jq")], .discover, mixed).map(\.title) == ["Install", "Copy names"])
    }

    @Test func updatesMenuSingleRow() {
        let rows = table(row("wget", installed: "1.0", latest: "2.0"))
        let menu = items([ref("wget")], .updates, rows)
        #expect(menu.map(\.title) == ["Update", "Ignore updates", "Skip version 2.0", "Uninstall…", "Show details",
                                      "Copy name"])
        #expect(menu.map(\.systemImage) == ["arrow.triangle.2.circlepath", "bell.slash", "forward", "trash",
                                            "info.circle", "doc.on.doc"])
        #expect(menu[2].action == .skipVersion("2.0"))
    }

    @Test func updatesMenuMultiRowHasNoSkipOrDetails() {
        let rows = table(row("wget", installed: "1.0", latest: "2.0"), row("jq", installed: "1.0", latest: "1.1"))
        let menu = items([ref("wget"), ref("jq")], .updates, rows)
        #expect(menu.map(\.title) == ["Update", "Ignore updates", "Uninstall…", "Copy names"])
    }

    @Test func ignoredRowOffersStopIgnoring() {
        let prefs = UpdatePreferences(store: MemoryStore())
        prefs.ignore([ref("wget")])
        let rows = table(row("wget", installed: "1.0", latest: "2.0"), row("jq", installed: "1.0", latest: "1.1"))
        #expect(items([ref("wget")], .updates, rows, prefs: prefs).map(\.title).contains("Stop ignoring"))
        // Mixed shows Ignore.
        let mixed = items([ref("wget"), ref("jq")], .updates, rows, prefs: prefs).map(\.title)
        #expect(mixed.contains("Ignore updates") && !mixed.contains("Stop ignoring"))
        let bothIgnored = UpdatePreferences(store: MemoryStore())
        bothIgnored.ignore([ref("wget"), ref("jq")])
        let titles = items([ref("wget"), ref("jq")], .updates, rows, prefs: bothIgnored)
        #expect(titles.first { $0.title == "Stop ignoring" }?.systemImage == "bell")
    }

    @Test func installedMenuOffersUpdateOnlyWhenOutdated() {
        let rows = table(row("wget", installed: "1.0"), row("jq", installed: "1.7"))
        #expect(items([ref("wget")], .installed, rows).map(\.title) == ["Uninstall…", "Show details", "Copy name"])
        let menu = items([ref("wget")], .installed, rows, outdated: [ref("wget")])
        #expect(menu.map(\.title) == ["Update", "Uninstall…", "Show details", "Copy name"])
        // One outdated ref among several is enough.
        let several = items([ref("wget"), ref("jq")], .installed, rows, outdated: [ref("wget")])
        #expect(several.map(\.title) == ["Update", "Uninstall…", "Copy names"])
    }

    @Test func mutatingItemsDisabledWhileRunning() {
        let rows = table(row("wget", installed: "1.0", latest: "2.0"))
        for (running, canRun) in [(true, true), (false, false)] {
            let menu = items([ref("wget")], .updates, rows, isRunning: running, canRun: canRun)
            for item in menu {
                let mutating = [RowAction.update, .uninstall, .install].contains(item.action)
                #expect(item.isEnabled == !mutating, "\(item.title) running=\(running) canRun=\(canRun)")
            }
        }
        let discover = items([ref("wget")], .discover, table(row("wget")), isRunning: true)
        #expect(discover.first?.action == .install && discover.first?.isEnabled == false)
        let idle = items([ref("wget")], .updates, rows)
        #expect(idle.allSatisfy { $0.isEnabled })
    }

    @Test func copyTextUsesDisplayNames() {
        let mas = row("497799835", engine: .mas, kind: .app, display: "Xcode")
        let rows = table(row("wget"), mas, row("jq"))
        let text = RowActions.copyText(for: [mas.id, ref("wget"), ref("jq")], rows: rows)
        #expect(text == "jq\nwget\nXcode")
        #expect(RowActions.copyText(for: [mas.id], rows: rows) == "Xcode")
        #expect(RowActions.copyText(for: [], rows: rows) == "")
    }
}
