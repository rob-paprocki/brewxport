import Testing
import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@MainActor @Suite struct SettingsTests {
    typealias F = AppFixtures

    /// What the system says when it refuses a login-item change.
    struct Refused: LocalizedError {
        var errorDescription: String? { "Operation not permitted." }
    }

    static let allMissing: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                                       .mas: .missing]

    /// A live-mode model that has started, with its window open, once engine detection has answered `engines`.
    func launched(_ engines: [EngineID: EngineStatus] = [:], store: MemoryStore = MemoryStore(),
                  executor: FakeRunExecutor = FakeRunExecutor(), notifier: FakeNotifier = FakeNotifier(),
                  loginItem: FakeLoginItem = FakeLoginItem(), window: Bool = true) async -> BrewxPortAppModel {
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: engines), executor: executor, store: store, notifier: notifier,
            loginItem: loginItem))
        model.mainWindowShowing = window
        model.start()
        _ = await waitUntil { model.enginesChecked }
        return model
    }

    /// Long enough for the model to have shown the one-time sheet if it was going to.
    func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    // MARK: Settings window

    @Test func settingsLabelsAndChoices() {
        #expect(SettingsModel.intervalLabel == "Check for updates")
        #expect(SettingsModel.modeLabel == "When updates are found")
        #expect(SettingsModel.notificationsLabel == "Show notifications")
        #expect(SettingsModel.openAtLoginLabel == "Open BrewxPort at login")
        #expect(CheckInterval.allCases.map(\.title)
                == ["Every hour", "Every 4 hours", "Every 12 hours", "Every 24 hours", "Never"])
        #expect(AutoUpdateMode.allCases.map(\.title)
                == ["Notify me", "Update what doesn't need a password", "Update everything"])
        // A fresh install shows the defaults.
        let form = SettingsModel(model: BrewxPortAppModel(services: F.services()))
        #expect(form.interval == .twelveHours)
        #expect(form.mode == .notify)
        #expect(form.settings.notificationsOn)
        #expect(!form.settings.openAtLogin)
        #expect(form.notificationsProblem == nil)
        #expect(form.loginItemNote == nil)
    }

    @Test func intervalChangeReschedules() {
        let hour: TimeInterval = 3600
        let scheduler = FakeScheduler()
        let store = MemoryStore()
        let model = BrewxPortAppModel(services: F.services(store: store, scheduler: scheduler))
        model.start()
        #expect(scheduler.interval == 12 * hour)
        let form = SettingsModel(model: model)
        // The Quit items follow the interval as it changes.
        nonisolated(unsafe) var quitTitleChanged = false
        withObservationTracking { _ = model.quitTitle } onChange: { quitTitleChanged = true }
        form.interval = .hourly
        #expect(scheduler.interval == hour)
        #expect(model.background.settings.interval == .hourly)
        #expect(store.data(forKey: "checkInterval") == Data("hourly".utf8))
        #expect(model.background.nextCheck != nil)
        // Never stops the schedule, takes BrewxPort out of the menu bar and drops "(stops update checks)".
        form.interval = .never
        #expect(scheduler.interval == nil)
        #expect(model.background.nextCheck == nil)
        #expect(!model.keepsRunningInMenuBar)
        #expect(quitTitleChanged)
        #expect(model.quitTitle == "Quit BrewxPort")
        form.interval = .daily
        #expect(scheduler.interval == 24 * hour)
        #expect(model.quitTitle == "Quit BrewxPort (stops update checks)")
        // The same choice again changes nothing.
        let count = scheduler.scheduleCount
        form.interval = .daily
        #expect(scheduler.scheduleCount == count)
        // The mode is stored and read again before every automatic run: nothing to reschedule.
        form.mode = .everything
        #expect(model.background.settings.mode == .everything)
        #expect(store.data(forKey: "autoUpdateMode") == Data("everything".utf8))
        #expect(scheduler.scheduleCount == count)
    }

    @Test func notificationDenialTurnsSwitchOff() async {
        let notifier = FakeNotifier(permission: false)
        let store = MemoryStore()
        let model = BrewxPortAppModel(services: F.services(store: store, notifier: notifier))
        let form = SettingsModel(model: model)
        let settings = model.background.settings
        // Turning them off asks nothing.
        await form.setNotifications(false)
        #expect(!settings.notificationsOn)
        #expect(notifier.permissionRequests == 0)
        #expect(form.notificationsProblem == nil)
        // Turning them on asks macOS. Refused: the switch goes off again and says where to allow them.
        await form.setNotifications(true)
        #expect(notifier.permissionRequests == 1)
        #expect(!settings.notificationsOn)
        #expect(store.data(forKey: "backgroundNotifications") == Data("0".utf8))
        #expect(form.notificationsProblem == "Allow notifications for BrewxPort in System Settings > Notifications.")
        // Allowed in System Settings since: on, and the message goes.
        notifier.permission = true
        await form.setNotifications(true)
        #expect(notifier.permissionRequests == 2)
        #expect(settings.notificationsOn)
        #expect(form.notificationsProblem == nil)
        // Off again: no question, no message.
        await form.setNotifications(false)
        #expect(notifier.permissionRequests == 2)
        #expect(!settings.notificationsOn)
    }

    @Test func standardAccountNote() {
        func note(_ admin: Bool?) -> String? {
            SettingsModel(model: BrewxPortAppModel(services: F.services(isAdministrator: admin))).standardAccountNote
        }
        #expect(note(false) == "Your account isn't an administrator, so updates that need a password are only notified.")
        #expect(note(true) == nil)
        // An account that couldn't be read keeps "Update everything" as it is (`effectiveMode`), so nothing's said.
        #expect(note(nil) == nil)
    }

    @Test func openAtLoginErrorsShowInline() {
        let loginItem = FakeLoginItem()
        let model = BrewxPortAppModel(services: F.services(loginItem: loginItem))
        let form = SettingsModel(model: model)
        let settings = model.background.settings
        // The system refuses: the switch stays off and says why, under it.
        loginItem.error = Refused()
        form.setOpenAtLogin(true)
        #expect(loginItem.changes == [true])
        #expect(!settings.openAtLogin)
        #expect(form.loginItemNote == "BrewxPort couldn't change its login item: Operation not permitted.")
        // Registered, but waiting for the person's approval: on, with where to approve it.
        loginItem.error = nil
        loginItem.approvalNeededOnRegister = true
        form.setOpenAtLogin(true)
        #expect(settings.openAtLogin)
        #expect(form.loginItemNote == "Approve BrewxPort in System Settings > General > Login Items.")
        // Approved in System Settings, then back to Settings (it appears, or BrewxPort becomes active): the note goes.
        loginItem.needsApproval = false
        loginItem.isEnabled = true
        form.refresh()
        #expect(settings.openAtLogin)
        #expect(form.loginItemNote == nil)
        // Removed in System Settings > General > Login Items: Settings appearing turns the switch off, only reading.
        loginItem.isEnabled = false
        form.refresh()
        #expect(!settings.openAtLogin)
        #expect(loginItem.changes == [true, true])
        // Turned off from Settings.
        loginItem.isEnabled = true
        form.refresh()
        form.setOpenAtLogin(false)
        #expect(loginItem.changes == [true, true, false])
        #expect(!settings.openAtLogin)
        #expect(form.loginItemNote == nil)
    }

    @Test func settingsWindowKeepsDockIcon() {
        // Checks on (the default): the Dock icon shows while any of BrewxPort's windows is open, Settings included.
        let model = BrewxPortAppModel(services: F.services())
        #expect(!model.showsDockIcon)
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = model.showsDockIcon } onChange: { changed = true }
        model.settingsWindowShowing = true
        #expect(changed)
        #expect(model.showsDockIcon)
        model.settingsWindowShowing = false
        #expect(!model.showsDockIcon)
        // The main window closes while Settings stays open: the icon stays.
        model.mainWindowShowing = true
        model.settingsWindowShowing = true
        model.mainWindowShowing = false
        #expect(model.showsDockIcon)
        model.settingsWindowShowing = false
        #expect(!model.showsDockIcon)
    }

    @Test func loginLaunchShowsWindowOnlyWithChecksOff() {
        // Checks on: a launch at login stays in the menu bar. Checks off: there's no menu bar, so the window shows.
        let model = BrewxPortAppModel(services: F.services())
        #expect(!model.opensWindowAtLoginLaunch)
        model.background.settings.interval = .never
        #expect(model.opensWindowAtLoginLaunch)
        model.background.settings.interval = .fourHours
        #expect(!model.opensWindowAtLoginLaunch)
        // The demo's menu bar always shows.
        let demo = BrewxPortAppModel(services: F.services(isDemo: true))
        demo.background.settings.interval = .never
        #expect(!demo.opensWindowAtLoginLaunch)
    }

    // MARK: The one-time sheet

    @Test func introShownOnceAfterSetup() async {
        let store = MemoryStore()
        // A Mac with no package manager gets the setup offer first; the one-time sheet waits until it's gone.
        let model = await launched(Self.allMissing, store: store)
        #expect(await waitUntil { model.setup.stage != .hidden })
        await settle()
        #expect(!model.showingBackgroundIntro)
        model.setup.notNow()
        #expect(await waitUntil { model.showingBackgroundIntro })
        #expect(BackgroundIntro.title == "BrewxPort now checks for updates")
        #expect(BackgroundIntro.body(for: .twelveHours)
                == "It checks every 12 hours and stays in the menu bar when you close its window. "
                + "You can change this in Settings.")
        #expect(BackgroundIntro.body(for: .hourly).hasPrefix("It checks every hour and stays"))
        model.closeBackgroundIntro()
        #expect(!model.showingBackgroundIntro)
        #expect(model.background.settings.introShown)
        #expect(store.data(forKey: "backgroundIntroShown") == Data("1".utf8))
        // Once: the next launch on the same settings doesn't show it, and neither does this one again.
        model.mainWindowShowing = false
        model.mainWindowShowing = true
        let next = await launched(store: store)
        await settle()
        #expect(!next.showingBackgroundIntro)
        #expect(!model.showingBackgroundIntro)
    }

    @Test func introNotOverOtherSheets() async {
        // Something modal is up when the launch's setup decision comes in (an open panel, say): the sheet waits.
        let model = BrewxPortAppModel(services: F.services())
        model.showingOpenPanel = true
        model.mainWindowShowing = true
        model.start()
        _ = await waitUntil { model.enginesChecked }
        await settle()
        #expect(!model.showingBackgroundIntro)
        model.showingOpenPanel = false
        #expect(await waitUntil { model.showingBackgroundIntro })
        // While it's up, nothing else opens over it or starts a run behind it.
        #expect(model.modalUp)
        #expect(!model.canOpenFile)
        #expect(!model.canMenuUpdate)
        model.closeBackgroundIntro()
        #expect(!model.modalUp)

        // A run is going (its password sheet could come at any moment): the sheet waits for it to end.
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let busy = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: busy)
        busy.perform(.install, on: [F.wget])
        #expect(await waitUntil { busy.run.isRunning })
        busy.mainWindowShowing = true
        busy.start()
        _ = await waitUntil { busy.enginesChecked }
        await settle()
        #expect(!busy.showingBackgroundIntro)
        executor.finish([.finished(0, 0), .done])
        #expect(await waitUntil { busy.showingBackgroundIntro })
    }

    @Test func introWaitsForWindowAndChecks() async {
        // A launch at login has no window: the sheet waits for it, and holds nothing back meanwhile.
        let model = await launched(window: false)
        await settle()
        #expect(!model.showingBackgroundIntro)
        #expect(!model.modalUp)
        model.mainWindowShowing = true
        #expect(await waitUntil { model.showingBackgroundIntro })
        // The window closes while it's up: it goes, unread, and comes back with the window.
        model.mainWindowShowing = false
        #expect(!model.showingBackgroundIntro)
        #expect(!model.background.settings.introShown)
        model.mainWindowShowing = true
        #expect(await waitUntil { model.showingBackgroundIntro })

        // Checks already turned off (Never): BrewxPort doesn't check, so it has nothing to say.
        let off = BrewxPortAppModel(services: F.services())
        off.background.settings.interval = .never
        off.mainWindowShowing = true
        off.start()
        _ = await waitUntil { off.enginesChecked }
        await settle()
        #expect(!off.showingBackgroundIntro)
    }

    @Test func introDoneKeepsChoices() async {
        let store = MemoryStore()
        let notifier = FakeNotifier()
        let loginItem = FakeLoginItem()
        let model = await launched(store: store, notifier: notifier, loginItem: loginItem)
        #expect(await waitUntil { model.showingBackgroundIntro })
        // It shows the settings as they are: notifications on, Open at login off.
        let settings = model.background.settings
        #expect(settings.notificationsOn)
        #expect(!settings.openAtLogin)
        // The person turns Open at login on in the sheet (registered at once, as in Settings), then clicks Done:
        // notifications are still on, so macOS is asked now.
        SettingsModel(model: model).setOpenAtLogin(true)
        #expect(loginItem.changes == [true])
        #expect(notifier.permissionRequests == 0)
        model.closeBackgroundIntro()
        #expect(await waitUntil { notifier.permissionRequests == 1 })
        #expect(settings.notificationsOn)
        #expect(settings.openAtLogin)
        #expect(settings.introShown)
        #expect(store.data(forKey: "openAtLogin") == Data("1".utf8))
        // A second close (Done, then the dismissal) asks nothing more.
        model.closeBackgroundIntro()
        await settle()
        #expect(notifier.permissionRequests == 1)

        // Notifications turned off in the sheet: closing keeps them off and asks nothing.
        let quiet = FakeNotifier()
        let other = await launched(notifier: quiet)
        #expect(await waitUntil { other.showingBackgroundIntro })
        other.background.settings.notificationsOn = false
        other.closeBackgroundIntro()
        await settle()
        #expect(quiet.permissionRequests == 0)
        #expect(!other.background.settings.notificationsOn)
        #expect(other.background.settings.introShown)

        // macOS refuses: they're turned off, as in Settings.
        let refusing = FakeNotifier(permission: false)
        let third = await launched(notifier: refusing)
        #expect(await waitUntil { third.showingBackgroundIntro })
        third.closeBackgroundIntro()
        #expect(await waitUntil { refusing.permissionRequests == 1 })
        #expect(await waitUntil { !third.background.settings.notificationsOn })
        #expect(third.background.settings.introShown)
    }
}
