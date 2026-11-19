import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor
struct DetailsModelTests {
    private func row(_ name: String, engine: EngineID = .homebrew, kind: PackageKind = .formula,
                     installed: String? = nil) -> PackageRow {
        PackageRow(package: Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                                    installedVersion: installed), arch: .arm64)
    }

    @Test func installAvailabilityForNanobrewCask() async {
        let cask = row("iterm2", engine: .nanobrew, kind: .cask)
        let catalog = FakeCatalog()
        catalog.scriptInfo(cask.id, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: cask.id)), hang: true))
        let model = DetailsModel(catalog: catalog)
        model.show(cask)
        #expect(model.installAvailability(isRunning: false, homebrewPresent: true) == .checking)

        let rooted = row("zoom", engine: .nanobrew, kind: .cask)
        catalog.scriptInfo(rooted.id, FakeCatalog.InfoScript(
            result: .success(PackageDetails(ref: rooted.id, installerNeedsRoot: true))))
        model.show(rooted)
        #expect(await waitUntil { model.details != nil })
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false)
                == .needsHomebrew(CaskRouting.needsHomebrewText(name: "zoom")))
        #expect(model.installAvailability(isRunning: false, homebrewPresent: true) == .ready)
        #expect(model.installAvailability(isRunning: true, homebrewPresent: true) == .running)

        let plain = row("rectangle", engine: .nanobrew, kind: .cask)
        catalog.scriptInfo(plain.id, FakeCatalog.InfoScript(
            result: .success(PackageDetails(ref: plain.id, installerNeedsRoot: false))))
        model.show(plain)
        #expect(await waitUntil { model.details != nil })
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false) == .ready)
    }

    @Test func installAvailabilityForOtherRows() {
        let model = DetailsModel(catalog: FakeCatalog())
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false) == .ready)
        model.show(row("wget", installed: "1.0"))
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false) == .alreadyInstalled)
        model.show(row("jq"))
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false) == .ready)
    }

    @Test func outdatedInstalledRowOffersUpdate() {
        let model = DetailsModel(catalog: FakeCatalog())
        let old = PackageRow(package: Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "ada-url"),
                                              displayName: "ada-url", installedVersion: "1", latestVersion: "2"),
                             arch: .arm64)
        model.show(old)
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false, isOutdated: true)
                == .updateAvailable(installed: "1", latest: "2"))
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false, isOutdated: false)
                == .alreadyInstalled)
        #expect(model.installAvailability(isRunning: true, homebrewPresent: false, isOutdated: true) == .running)
        let same = PackageRow(package: Package(id: old.id, displayName: "ada-url", installedVersion: "2",
                                               latestVersion: "2"), arch: .arm64)
        model.show(same)
        #expect(model.installAvailability(isRunning: false, homebrewPresent: false, isOutdated: true)
                == .alreadyInstalled)
    }

    @Test func lateInfoForOldSelectionIgnored() async {
        let a = row("a"), b = row("b")
        let catalog = FakeCatalog()
        catalog.scriptInfo(a.id, FakeCatalog.InfoScript(
            result: .success(PackageDetails(ref: a.id, summary: "A")), delay: .milliseconds(200)))
        catalog.scriptInfo(b.id, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: b.id, summary: "B"))))
        let model = DetailsModel(catalog: catalog)
        model.show(a)
        model.show(b)
        #expect(await waitUntil { model.details != nil })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(model.details?.ref == b.id)
        #expect(model.row?.id == b.id)
        #expect(!model.loading)
        // The cancelled load for A must not leave its cancellation behind as B's error.
        #expect(model.error == nil)
    }

    @Test func detailsErrorShownNotEmpty() async {
        let a = row("a")
        let catalog = FakeCatalog()
        catalog.scriptInfo(a.id, FakeCatalog.InfoScript(result: .failure(EngineError(engine: .homebrew, message: ""))))
        let model = DetailsModel(catalog: catalog)
        model.show(a)
        #expect(await waitUntil { model.error != nil })
        #expect(model.error?.isEmpty == false)
        #expect(model.details == nil)
        #expect(!model.loading)

        catalog.scriptInfo(a.id, FakeCatalog.InfoScript(result: .failure(EngineError(engine: .homebrew, message: "boom"))))
        model.show(row("b"))
        model.show(a)
        #expect(await waitUntil { model.error == "Homebrew: boom" })
    }

    @Test func showingNilClearsEverything() async {
        let a = row("a")
        let catalog = FakeCatalog()
        catalog.scriptInfo(a.id, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: a.id))))
        let model = DetailsModel(catalog: catalog)
        model.show(a)
        #expect(await waitUntil { model.details != nil })
        model.options.extraArgs = "-s"
        model.show(nil)
        #expect(model.row == nil && model.details == nil && model.error == nil && !model.loading)
        #expect(model.options == InstallOptionsDraft())
    }
}
