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
                     engine: EngineID = .homebrew, kind: PackageKind = .formula, display: String? = nil,
                     fullName: String? = nil) -> PackageRow {
        PackageRow(package: Package(id: ref(name, engine: engine, kind: kind), displayName: display ?? name,
                                    installedVersion: installed, latestVersion: latest, fullName: fullName), arch: .arm64)
    }

    private func table(_ rows: PackageRow...) -> [PackageRef: PackageRow] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    private func items(_ refs: Set<PackageRef>, _ view: PackageView, _ rows: [PackageRef: PackageRow],
                       outdated: Set<PackageRef> = [], prefs: UpdatePreferences? = nil,
                       isRunning: Bool = false, canRun: Bool = true, moveTargets: [EngineID] = [],
                       isDemo: Bool = false) -> [RowActionItem] {
        RowActions.items(for: refs, in: view, rows: rows, outdated: outdated,
                         prefs: prefs ?? UpdatePreferences(store: MemoryStore()), isRunning: isRunning, canRun: canRun,
                         moveTargets: moveTargets, isDemo: isDemo)
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

    @Test func bundlesMenuHasNoUninstallOrIgnore() {
        // jq can be installed; wget is already installed; curl's engine is missing (neither installed nor installable).
        let rows = table(row("jq"), row("wget", installed: "1.0"), row("curl", engine: .macports, kind: .port))
        let jq = ref("jq"), wget = ref("wget"), curl = ref("curl", engine: .macports, kind: .port)
        func menu(_ refs: Set<PackageRef>, isRunning: Bool = false, canRun: Bool = true) -> [RowActionItem] {
            RowActions.items(for: refs, in: .bundles, rows: rows, outdated: [wget],
                             prefs: UpdatePreferences(store: MemoryStore()), isRunning: isRunning, canRun: canRun,
                             installable: [jq])
        }
        #expect(menu([jq]).map(\.title) == ["Install", "Show details", "Copy name"])
        #expect(menu([jq]).first?.isEnabled == true)
        #expect(menu([wget]).map(\.title) == ["Show details", "Copy name"])
        #expect(menu([curl]).map(\.title) == ["Show details", "Copy name"])
        #expect(menu([jq, wget, curl]).map(\.title) == ["Install", "Copy names"])
        for refs: Set<PackageRef> in [[jq], [wget], [jq, wget, curl]] {
            let actions = menu(refs).map(\.action)
            #expect(!actions.contains(.uninstall))
            #expect(!actions.contains(.ignore))
            #expect(!actions.contains(.update))
            #expect(!actions.contains { if case .skipVersion = $0 { true } else { false } })
        }
        #expect(menu([jq], isRunning: true).first?.isEnabled == false)
        #expect(menu([jq], canRun: false).first?.isEnabled == false)
    }

    // MARK: Move to

    private static let allMovable: [EngineID] = [.homebrew, .nanobrew, .macports]

    @Test func installedRowOffersMoveTargets() {
        let rows = table(row("ripgrep", installed: "14"), row("curl", installed: "8", engine: .macports, kind: .port))
        let menu = items([ref("ripgrep")], .installed, rows, moveTargets: Self.allMovable)
        #expect(menu.map(\.title) == ["Uninstall…", "nanobrew", "MacPorts", "Show details", "Copy name"])
        #expect(menu.filter { $0.isMove }.map(\.action) == [.moveTo(.nanobrew), .moveTo(.macports)])
        #expect(menu.filter { $0.isMove }.allSatisfy { $0.isEnabled && $0.help == nil })
        // A port is offered Homebrew and nanobrew; only the present targets are offered.
        let port = ref("curl", engine: .macports, kind: .port)
        #expect(items([port], .installed, rows, moveTargets: Self.allMovable).filter { $0.isMove }.map(\.action)
                    == [.moveTo(.homebrew), .moveTo(.nanobrew)])
        #expect(items([port], .installed, rows, moveTargets: [.macports, .homebrew]).filter { $0.isMove }.map(\.action)
                    == [.moveTo(.homebrew)])
        // No other movable manager: no Move to.
        #expect(!items([ref("ripgrep")], .installed, rows, moveTargets: [.homebrew]).contains { $0.isMove })
        // Only on Installed.
        let updates = table(row("ripgrep", installed: "14", latest: "15"))
        #expect(!items([ref("ripgrep")], .updates, updates, moveTargets: Self.allMovable).contains { $0.isMove })
    }

    @Test func caskRowHasNoMove() {
        let cask = row("firefox", installed: "1", kind: .cask)
        let app = row("497799835", installed: "1", engine: .mas, kind: .app, display: "Xcode")
        let rows = table(cask, app)
        #expect(!items([cask.id], .installed, rows, moveTargets: Self.allMovable).contains { $0.isMove })
        #expect(!items([app.id], .installed, rows, moveTargets: Self.allMovable).contains { $0.isMove })
    }

    @Test func tapFormulaHasNoMove() {
        let rows = table(row("tool", installed: "1", fullName: "me/tools/tool"))
        #expect(!items([ref("tool")], .installed, rows, moveTargets: Self.allMovable).contains { $0.isMove })
    }

    @Test func multipleSelectionHasNoMove() {
        let rows = table(row("ripgrep", installed: "14"), row("jq", installed: "1.7"))
        #expect(!items([ref("ripgrep"), ref("jq")], .installed, rows, moveTargets: Self.allMovable)
            .contains { $0.isMove })
    }

    @Test func moveDisabledWhileRunning() {
        let rows = table(row("ripgrep", installed: "14"))
        for (running, canRun) in [(true, true), (false, false)] {
            let moves = items([ref("ripgrep")], .installed, rows, isRunning: running, canRun: canRun,
                              moveTargets: Self.allMovable).filter { $0.isMove }
            #expect(moves.count == 2)
            #expect(moves.allSatisfy { !$0.isEnabled })
        }
    }

    @Test func moveDisabledInDemoMode() {
        let rows = table(row("ripgrep", installed: "14"))
        let moves = items([ref("ripgrep")], .installed, rows, moveTargets: Self.allMovable, isDemo: true)
            .filter { $0.isMove }
        #expect(moves.count == 2)
        #expect(moves.allSatisfy { !$0.isEnabled && $0.help == "Not available in demo mode" })
    }
}
