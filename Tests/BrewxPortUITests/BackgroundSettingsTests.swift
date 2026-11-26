import Testing
import Foundation
@testable import BrewxPortUI

@MainActor @Suite struct BackgroundSettingsTests {
    static let twelveHours: TimeInterval = 12 * 3600

    @Test func defaultsMatchSpec() {
        let settings = BackgroundSettings(store: MemoryStore(), testIntervalOverride: nil)
        #expect(settings.interval == .twelveHours)
        #expect(settings.mode == .notify)
        #expect(settings.notificationsOn)
        #expect(settings.openAtLogin == false)
        #expect(settings.introShown == false)
        #expect(settings.checksOn)
        #expect(settings.effectiveInterval == Self.twelveHours)
    }

    @Test func intervalChoicesInSeconds() {
        #expect(CheckInterval.allCases == [.hourly, .fourHours, .twelveHours, .daily, .never])
        let hour: TimeInterval = 3600
        let seconds: [TimeInterval?] = [hour, 4 * hour, 12 * hour, 24 * hour, nil]
        #expect(CheckInterval.allCases.map(\.seconds) == seconds)
        #expect(AutoUpdateMode.allCases == [.notify, .passwordFree, .everything])
    }

    @Test func settingsPersist() {
        let store = MemoryStore()
        let first = BackgroundSettings(store: store, testIntervalOverride: nil)
        first.interval = .fourHours
        first.mode = .everything
        first.notificationsOn = false
        first.openAtLogin = true
        first.introShown = true

        let second = BackgroundSettings(store: store, testIntervalOverride: nil)
        #expect(second.interval == .fourHours)
        #expect(second.mode == .everything)
        #expect(second.notificationsOn == false)
        #expect(second.openAtLogin)
        #expect(second.introShown)

        // And back again: a flag turned back on (or off) is remembered too, not just the first change.
        second.interval = .daily
        second.mode = .passwordFree
        second.notificationsOn = true
        second.openAtLogin = false
        let third = BackgroundSettings(store: store, testIntervalOverride: nil)
        #expect(third.interval == .daily)
        #expect(third.mode == .passwordFree)
        #expect(third.notificationsOn)
        #expect(third.openAtLogin == false)
        #expect(third.introShown)
    }

    @Test func settingsUseTheirOwnKeys() {
        let store = MemoryStore()
        let settings = BackgroundSettings(store: store, testIntervalOverride: nil)
        settings.interval = .hourly
        settings.mode = .passwordFree
        settings.notificationsOn = false
        settings.openAtLogin = true
        settings.introShown = true
        #expect(store.data(forKey: "checkInterval") == Data("hourly".utf8))
        #expect(store.data(forKey: "autoUpdateMode") == Data("passwordFree".utf8))
        #expect(store.data(forKey: "backgroundNotifications") == Data("0".utf8))
        #expect(store.data(forKey: "openAtLogin") == Data("1".utf8))
        #expect(store.data(forKey: "backgroundIntroShown") == Data("1".utf8))
    }

    @Test func unreadableValuesFallBackToDefaults() {
        let store = MemoryStore()
        // A choice a later version added, or a damaged value, reads as the default rather than something else.
        store.set(Data("fortnightly".utf8), forKey: "checkInterval")
        store.set(Data("sometimes".utf8), forKey: "autoUpdateMode")
        store.set(Data("yes".utf8), forKey: "backgroundNotifications")
        store.set(Data("yes".utf8), forKey: "openAtLogin")
        store.set(Data("yes".utf8), forKey: "backgroundIntroShown")
        let settings = BackgroundSettings(store: store, testIntervalOverride: nil)
        #expect(settings.interval == .twelveHours)
        #expect(settings.mode == .notify)
        #expect(settings.notificationsOn)
        #expect(settings.openAtLogin == false)
        #expect(settings.introShown == false)
    }

    @Test func testOverrideOnlyAtLeastSixtySeconds() {
        func effective(_ override: TimeInterval?) -> TimeInterval? {
            BackgroundSettings(store: MemoryStore(), testIntervalOverride: override).effectiveInterval
        }
        #expect(effective(nil) == Self.twelveHours)
        #expect(effective(0) == Self.twelveHours)
        #expect(effective(-120) == Self.twelveHours)
        #expect(effective(59) == Self.twelveHours)
        #expect(effective(59.9) == Self.twelveHours)
        #expect(effective(60) == 60)
        #expect(effective(120) == 120)

        // The override replaces whichever interval is chosen.
        let settings = BackgroundSettings(store: MemoryStore(), testIntervalOverride: 120)
        settings.interval = .daily
        #expect(settings.effectiveInterval == 120)
    }

    @Test func neverMeansChecksOff() {
        let settings = BackgroundSettings(store: MemoryStore(), testIntervalOverride: nil)
        settings.interval = .never
        #expect(settings.checksOn == false)
        #expect(settings.effectiveInterval == nil)
        settings.interval = .hourly
        #expect(settings.checksOn)
        #expect(settings.effectiveInterval == 3600)

        // Never wins over the hidden test interval: checks stay off.
        let overridden = BackgroundSettings(store: MemoryStore(), testIntervalOverride: 120)
        overridden.interval = .never
        #expect(overridden.checksOn == false)
        #expect(overridden.effectiveInterval == nil)
    }

    @Test func testIntervalIsReadWithoutDisk() {
        #expect(BackgroundSettings.testInterval(from: nil) == nil)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: 120)) == 120)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: 60)) == 60)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: 90.5)) == 90.5)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: 59)) == nil)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: 0)) == nil)
        #expect(BackgroundSettings.testInterval(from: NSNumber(value: -300)) == nil)
        // `defaults write` without `-int` stores text.
        #expect(BackgroundSettings.testInterval(from: "120" as NSString) == 120)
        #expect(BackgroundSettings.testInterval(from: " 300 " as NSString) == 300)
        #expect(BackgroundSettings.testInterval(from: "30" as NSString) == nil)
        #expect(BackgroundSettings.testInterval(from: "soon" as NSString) == nil)
        #expect(BackgroundSettings.testInterval(from: "" as NSString) == nil)
        #expect(BackgroundSettings.testInterval(from: kCFBooleanTrue) == nil)
        #expect(BackgroundSettings.testInterval(from: [120] as NSArray) == nil)
    }

    @Test func testIntervalLivesInTheAppDomain() {
        #expect(BackgroundSettings.testIntervalKey == "BrewxPortTestCheckIntervalSeconds")
        #expect(StartupPolicy.domain == "com.brewxport.app")
    }
}
