import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

struct FakeReceipts: InstallerReceiptReading {
    var dates: [String: Date] = [:]
    func installDate(_ packageID: String) async -> Date? { dates[packageID] }
}

@MainActor @Suite struct SetupModelTests {
    typealias F = AppFixtures
    static let arm = HostInfo(appleSilicon: true, macOSMajor: 15)
    static let intel = HostInfo(appleSilicon: false, macOSMajor: 15)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func present(_ path: String) -> EngineStatus { .present(path: URL(fileURLWithPath: path), version: "1") }
    static let none: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing, .mas: .missing]
    static let brewPresent: [EngineID: EngineStatus] = [.homebrew: present("/opt/homebrew/bin/brew"), .macports: .missing]

    /// A model wired to a fake world. `started` collects the engines it asked to set up.
    final class Box { var started: [EngineID] = []; var runStarts = true; var statuses: [EngineID: EngineStatus] = [:]; var planProblem: String? }

    func make(statuses: [EngineID: EngineStatus], host: HostInfo = arm, receipts: FakeReceipts = FakeReceipts(),
              helper: FakeHelperManager? = nil, isDemo: Bool = false, store: MemoryStore = MemoryStore(),
              box: Box = Box(), isAdministrator: Bool? = true, setupProblem: String? = nil
    ) -> (SetupModel, Box, MemoryStore) {
        box.statuses = statuses
        let services = F.services(helper: helper, isDemo: isDemo, setupProblem: setupProblem,
                                  isAdministrator: isAdministrator, hostInfo: host, receipts: receipts, store: store)
        let model = SetupModel(services: services)
        model.connect(statuses: { box.statuses }, runSetup: { engine in box.started.append(engine); return box.runStarts },
                      planProblem: { box.planProblem })
        return (model, box, store)
    }

    static func choice(app: Date = now, marker: Date?) -> FakeReceipts {
        var dates = [InstallerReceipt.appPackageID: app]
        if let marker { dates[InstallerReceipt.setupChoicePackageID] = marker }
        return FakeReceipts(dates: dates)
    }

    @Test func noEngineShowsOffer() async {
        let (model, _, _) = make(statuses: Self.none)
        await model.start()
        #expect(model.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
    }

    @Test func masAloneCountsAsPresent() async {
        let (model, _, _) = make(statuses: Self.none.merging([.mas: Self.present("/opt/homebrew/bin/mas")]) { $1 })
        await model.start()
        #expect(model.stage == .hidden)
    }

    @Test func enginePresentAndNoChoiceHidden() async {
        let (model, box, _) = make(statuses: Self.brewPresent)
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func freshPkgChoiceStartsRecommended() async {
        let receipts = Self.choice(marker: Self.now)
        let (model, box, _) = make(statuses: Self.none, receipts: receipts)
        await model.start()
        #expect(box.started == [.homebrew])
        #expect(model.stage == .running)
    }

    @Test func freshPkgChoiceStartsEvenWhenAnotherEngineIsPresent() async {
        let receipts = Self.choice(marker: Self.now.addingTimeInterval(-30))
        let (model, box, _) = make(statuses: [.macports: Self.present("/opt/local/bin/port")], receipts: receipts)
        await model.start()
        #expect(box.started == [.homebrew])
    }

    @Test func stalePkgChoiceIgnored() async {
        let receipts = Self.choice(marker: Self.now.addingTimeInterval(-3600))
        let (model, box, _) = make(statuses: Self.brewPresent.merging([.homebrew: .missing, .macports: Self.present("/opt/local/bin/port")]) { $1 },
                                   receipts: receipts)
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func markerWithoutAppReceiptIsNotCurrent() async {
        let receipts = FakeReceipts(dates: [InstallerReceipt.setupChoicePackageID: Self.now])
        let (model, box, _) = make(statuses: [.macports: Self.present("/opt/local/bin/port")], receipts: receipts)
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func markerJustInsideTheToleranceCounts() async {
        let receipts = Self.choice(marker: Self.now.addingTimeInterval(-60))
        let (model, box, _) = make(statuses: Self.none, receipts: receipts)
        await model.start()
        #expect(box.started == [.homebrew])
    }

    @Test func markerJustOutsideTheToleranceDoesNot() async {
        let receipts = Self.choice(marker: Self.now.addingTimeInterval(-61))
        let (model, box, _) = make(statuses: [.macports: Self.present("/opt/local/bin/port")], receipts: receipts)
        await model.start()
        #expect(box.started.isEmpty)
    }

    @Test func notNowRemembered() async {
        let store = MemoryStore()
        let (model, _, _) = make(statuses: Self.none, store: store)
        await model.start()
        model.notNow()
        #expect(model.stage == .hidden)
        #expect(store.data(forKey: "setupDismissed") != nil)
        // A new launch with the same store stays quiet.
        let (again, _, _) = make(statuses: Self.none, store: store)
        await again.start()
        #expect(again.stage == .hidden)
    }

    @Test func succeededRunIsFinishedAndRemembered() async {
        let (model, box, store) = make(statuses: Self.none)
        await model.start()
        model.setUp(.homebrew)
        #expect(box.started == [.homebrew])
        #expect(model.stage == .running)
        model.runEnded()
        // Not decided until the engine check after the run.
        #expect(model.stage == .running)
        box.statuses[.homebrew] = Self.present("/opt/homebrew/bin/brew")
        model.enginesRechecked()
        #expect(model.stage == .finished)
        #expect(store.data(forKey: "setupDismissed") != nil)
    }

    @Test func failedOrCancelledRunIsFailedAndNotDismissed() async {
        let (model, box, store) = make(statuses: Self.none)
        await model.start()
        model.setUp(.homebrew)
        model.runEnded()
        model.enginesRechecked()
        guard case .failed(let engine, let reason) = model.stage else { Issue.record("not failed"); return }
        #expect(engine == .homebrew)
        #expect(reason == "Homebrew wasn't set up. The run panel shows what went wrong.")
        #expect(store.data(forKey: "setupDismissed") == nil)
        model.retry()
        #expect(box.started == [.homebrew, .homebrew])
        #expect(model.stage == .running)
        model.notNow()
        #expect(model.stage == .hidden)
        #expect(store.data(forKey: "setupDismissed") != nil)
    }

    @Test func failedPkgRunStaysVisible() async {
        let (model, _, store) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now))
        await model.start()
        model.runEnded()
        model.enginesRechecked()
        if case .failed = model.stage {} else { Issue.record("not failed") }
        #expect(store.data(forKey: "setupDismissed") == nil)
    }

    @Test func helperApprovalThenContinues() async {
        let helper = FakeHelperManager()
        let (model, box, _) = make(statuses: Self.none, helper: helper)
        await model.start()
        model.helperStateChanged(.requiresApproval)
        model.setUp(.macports)
        #expect(model.stage == .needsHelperApproval)
        #expect(box.started.isEmpty)
        model.helperStateChanged(.requiresApproval)
        #expect(model.stage == .needsHelperApproval)
        model.helperStateChanged(.enabled)
        #expect(box.started == [.macports])
        #expect(model.stage == .running)
    }

    @Test func enabledHelperStartsAtOnce() async {
        let (model, box, _) = make(statuses: Self.none, helper: FakeHelperManager())
        await model.start()
        model.helperStateChanged(.enabled)
        model.setUp(.homebrew)
        #expect(box.started == [.homebrew])
    }

    @Test func offerSetUpThatDoesNotStartIsCannotSetUpBusy() async {
        let box = Box()
        box.runStarts = false
        let (model, _, _) = make(statuses: Self.none, box: box)
        await model.start()
        model.setUp(.homebrew)
        #expect(model.stage == .cannotSetUp(engine: .homebrew,
                                            reason: "Another task is in progress. Try again in a moment."))
        box.runStarts = true
        model.retry()
        #expect(model.stage == .running)
    }

    @Test func pkgChoiceOnStandardAccountIsCannotSetUp() async {
        let box = Box()
        box.runStarts = false
        let (model, _, store) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now), box: box,
                                     isAdministrator: false)
        await model.start()
        #expect(model.stage == .cannotSetUp(engine: .homebrew,
                                            reason: "Setting up Homebrew needs an administrator account."))
        #expect(store.data(forKey: "setupDismissed") == nil)
    }

    @Test func standardAccountWithALiveHelperIsCannotSetUpNotApproval() async {
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now),
                                   helper: FakeHelperManager(), isAdministrator: false)
        await model.start()
        model.helperStateChanged(.requiresApproval)
        #expect(model.stage == .cannotSetUp(engine: .homebrew,
                                            reason: "Setting up Homebrew needs an administrator account."))
        #expect(box.started.isEmpty)
    }

    @Test func standardAccountOfferSetUpExplainsInsteadOfApproval() async {
        let (model, box, _) = make(statuses: Self.none, helper: FakeHelperManager(), isAdministrator: false)
        await model.start()
        model.helperStateChanged(.requiresApproval)
        model.setUp(.macports)
        #expect(model.stage == .cannotSetUp(engine: .macports,
                                            reason: "Setting up MacPorts needs an administrator account."))
        #expect(box.started.isEmpty)
    }

    @Test func nothingShowsBeforeTheHelperFirstAnswers() async {
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now),
                                   helper: FakeHelperManager())
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
        model.helperStateChanged(.requiresApproval)
        #expect(model.stage == .needsHelperApproval)
    }

    @Test func firstHelperAnswerEnabledStartsTheWaitingSetupWithoutASheet() async {
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now),
                                   helper: FakeHelperManager())
        await model.start()
        model.helperStateChanged(.enabled)
        #expect(box.started == [.homebrew])
        #expect(model.stage == .running)
    }

    @Test func offerSaysItIsCheckingTheHelperUntilItsFirstAnswer() async {
        let (model, box, _) = make(statuses: Self.none, helper: FakeHelperManager())
        await model.start()
        #expect(!model.waitingForHelper)
        model.setUp(.macports)
        #expect(model.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
        #expect(model.waitingForHelper)
        #expect(box.started.isEmpty)
        model.helperStateChanged(.enabled)
        #expect(!model.waitingForHelper)
        #expect(box.started == [.macports])
    }

    @Test func notNowWhileCheckingTheHelperStopsWaiting() async {
        let (model, box, _) = make(statuses: Self.none, helper: FakeHelperManager())
        await model.start()
        model.setUp(.homebrew)
        model.notNow()
        #expect(!model.waitingForHelper)
        model.helperStateChanged(.enabled)
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func noFileMenuOfferWhileThePkgChoiceWaitsForTheHelper() async {
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now),
                                   helper: FakeHelperManager())
        await model.start()
        #expect(model.stage == .hidden)
        #expect(model.waitingForHelper)
        #expect(!model.canShowOffer)
        model.showOffer()
        #expect(model.stage == .hidden)
        model.helperStateChanged(.enabled)
        #expect(box.started == [.homebrew])
        #expect(!model.waitingForHelper)
    }

    @Test func masIsNotOfferedWithoutHomebrewOrMacPorts() async {
        let (model, _, _) = make(statuses: Self.none)
        await model.start()
        #expect(model.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
        let withBrew = Self.none.merging([.homebrew: Self.present("/opt/homebrew/bin/brew")]) { $1 }
        let (later, _, _) = make(statuses: withBrew)
        later.showOffer()
        #expect(later.stage == .offer(recommended: .macports, others: [.nanobrew, .mas]))
    }

    @Test func offerLeavesOutEnginesThatAreNotWorking() {
        let broken = EngineStatus.unusable(path: URL(fileURLWithPath: "/opt/local/bin/port"), reason: "bad")
        let (model, _, _) = make(statuses: Self.brewPresent.merging([.macports: broken, .nanobrew: .missing,
                                                                     .mas: .missing]) { $1 })
        model.showOffer()
        #expect(model.stage == .offer(recommended: .nanobrew, others: [.mas]))
    }

    @Test func aPlanWithNothingToRunShowsItsProblem() async {
        let box = Box()
        box.runStarts = false
        box.planProblem = "Set up Homebrew or MacPorts first: mas installs through one of them."
        let (model, _, _) = make(statuses: Self.none, box: box)
        await model.start()
        model.setUp(.mas)
        #expect(model.stage == .cannotSetUp(engine: .mas, reason: box.planProblem!))
    }

    @Test func setupProblemTextIsUsed() async {
        let box = Box()
        box.runStarts = false
        let (model, _, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now), box: box,
                                 setupProblem: "Not signed.")
        await model.start()
        #expect(model.stage == .cannotSetUp(engine: .homebrew, reason: "Not signed."))
    }

    @Test func pkgChoiceStartsASetupOnlyOnce() async {
        let store = MemoryStore()
        let unusable = EngineStatus.unusable(path: URL(fileURLWithPath: "/x"), reason: "broken")
        let statuses = Self.none.merging([.homebrew: unusable]) { $1 }
        let (first, box1, _) = make(statuses: statuses, receipts: Self.choice(marker: Self.now), store: store)
        await first.start()
        #expect(box1.started == [.homebrew])
        // The next launch, same marker: no second auto-start, and an unusable engine isn't absence, so no offer.
        let (second, box2, _) = make(statuses: statuses, receipts: Self.choice(marker: Self.now), store: store)
        await second.start()
        #expect(box2.started.isEmpty)
        #expect(second.stage == .hidden)
        // With everything missing it falls back to the normal offer.
        let (third, box3, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now), store: store)
        await third.start()
        #expect(box3.started.isEmpty)
        if case .offer = third.stage {} else { Issue.record("expected the offer") }
        // A newer install of the pkg starts one again.
        let newer = Self.choice(app: Self.now.addingTimeInterval(500), marker: Self.now.addingTimeInterval(500))
        let (fourth, box4, _) = make(statuses: statuses, receipts: newer, store: store)
        await fourth.start()
        #expect(box4.started == [.homebrew])
    }

    @Test func newerPkgChoiceBeatsEarlierNotNow() async {
        let store = MemoryStore()
        store.set(Data(String(Self.now.timeIntervalSince1970 - 100).utf8), forKey: "setupDismissed")
        let (model, box, _) = make(statuses: Self.brewPresent.merging([.homebrew: .missing]) { $1 },
                                   receipts: Self.choice(marker: Self.now), store: store)
        await model.start()
        #expect(box.started == [.homebrew])
    }

    @Test func olderPkgChoiceLosesToLaterNotNow() async {
        let store = MemoryStore()
        store.set(Data(String(Self.now.timeIntervalSince1970 + 100).utf8), forKey: "setupDismissed")
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now), store: store)
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func oldFlagValueReadsAsLongAgo() async {
        let store = MemoryStore()
        store.set(Data("1".utf8), forKey: "setupDismissed")
        let (model, box, _) = make(statuses: Self.none, receipts: Self.choice(marker: Self.now), store: store)
        await model.start()
        #expect(box.started == [.homebrew])
        let (quiet, _, _) = make(statuses: Self.none, store: store)
        await quiet.start()
        #expect(quiet.stage == .hidden)
    }

    @Test func unusableOrUnansweredProbeIsNotAbsence() async {
        let unusable = EngineStatus.unusable(path: URL(fileURLWithPath: "/x"), reason: "broken")
        let (model, _, _) = make(statuses: Self.none.merging([.macports: unusable]) { $1 })
        await model.start()
        #expect(model.stage == .hidden)
    }

    @Test func demoNeverShows() async {
        let receipts = Self.choice(marker: Self.now)
        let (model, box, _) = make(statuses: Self.none, receipts: receipts, isDemo: true)
        await model.start()
        #expect(model.stage == .hidden)
        #expect(box.started.isEmpty)
    }

    @Test func intelRecommendsMacPorts() async {
        let (model, _, _) = make(statuses: Self.none, host: Self.intel)
        await model.start()
        #expect(model.stage == .offer(recommended: .macports, others: [.nanobrew]))
    }

    @Test func intelPkgChoiceSetsUpMacPorts() async {
        let (model, box, _) = make(statuses: Self.none, host: Self.intel, receipts: Self.choice(marker: Self.now))
        await model.start()
        #expect(box.started == [.macports])
    }

    @Test func showOfferAfterNotNow() async {
        let (model, _, _) = make(statuses: Self.none)
        await model.start()
        model.notNow()
        #expect(model.stage == .hidden)
        #expect(model.canShowOffer)
        model.showOffer()
        #expect(model.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
        #expect(!model.canShowOffer)
    }

    @Test func showOfferSkipsWhatIsPresent() {
        let (model, _, _) = make(statuses: Self.brewPresent.merging([.nanobrew: .missing, .mas: .missing]) { $1 })
        model.showOffer()
        #expect(model.stage == .offer(recommended: .macports, others: [.nanobrew, .mas]))
    }

    @Test func showOfferOnIntelLeavesOutHomebrew() {
        let (model, _, _) = make(statuses: Self.none, host: Self.intel)
        model.showOffer()
        #expect(model.stage == .offer(recommended: .macports, others: [.nanobrew]))
    }

    @Test func showOfferNeedsSomethingToOffer() {
        let all = Dictionary(uniqueKeysWithValues: [EngineID.homebrew, .macports, .nanobrew, .mas].map {
            ($0, Self.present("/x/\($0.rawValue)"))
        })
        let (model, _, _) = make(statuses: all)
        #expect(!model.canShowOffer)
        model.showOffer()
        #expect(model.stage == .hidden)
    }

    @Test func showOfferNotInDemoAndNotWhileRunning() async {
        let (demo, _, _) = make(statuses: Self.none, isDemo: true)
        #expect(!demo.canShowOffer)
        demo.showOffer()
        #expect(demo.stage == .hidden)
        let (model, _, _) = make(statuses: Self.none)
        await model.start()
        model.setUp(.homebrew)
        #expect(model.stage == .running)
        model.showOffer()
        #expect(model.stage == .running)
    }

    @Test func previewOfferWorksInDemo() {
        let (model, _, _) = make(statuses: Self.none, isDemo: true)
        model.previewOffer()
        #expect(model.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
    }

    @Test func dismissIsNotNowExceptWhenFinished() async {
        let (model, box, store) = make(statuses: Self.none)
        await model.start()
        model.dismiss()
        #expect(model.stage == .hidden)
        #expect(store.data(forKey: SetupModel.dismissedKey) != nil)
        model.showOffer()
        model.setUp(.homebrew)
        #expect(model.engineBeingSetUp == .homebrew)
        box.statuses = [.homebrew: Self.present("/opt/homebrew/bin/brew")]
        model.runEnded()
        model.enginesRechecked()
        #expect(model.stage == .finished)
        model.dismiss()
        #expect(model.stage == .hidden)
    }

    @Test func detailLinesMatchTheSpikeSizes() {
        #expect(SetupCopy.detail(.homebrew) == "About 160 MB. Needs an administrator password.")
        #expect(SetupCopy.detail(.macports)
                == "About 8 MB, plus Apple's Command Line Tools (about 1.3 GB) if you don't have them. Needs an administrator password.")
        #expect(SetupCopy.detail(.nanobrew) == "A small download. Needs an administrator password.")
        #expect(SetupCopy.detail(.mas)
                == "Installed through Homebrew or MacPorts. Through MacPorts it asks for an administrator password.")
    }

    @Test func previewFirstLaunchShowsNothingInstalled() async {
        let model = BrewxPortAppModel(services: F.services(isDemo: true))
        model.previewFirstLaunch()
        #expect(model.engineStatuses.values.allSatisfy { $0 == .missing })
        #expect(model.setup.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
    }

    @Test func pkgutilPlistParsing() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>install-time</key><integer>1800000000</integer>
        <key>pkgid</key><string>x</string></dict></plist>
        """
        #expect(PkgutilReceipts.installDate(fromPlist: Data(plist.utf8)) == Self.now)
        #expect(PkgutilReceipts.installDate(fromPlist: Data("nope".utf8)) == nil)
    }
}
