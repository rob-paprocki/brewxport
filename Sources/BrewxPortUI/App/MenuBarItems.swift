import AppKit
import Foundation
import BrewxPortCore

/// What a menu bar menu item does when it's chosen.
public enum MenuBarAction: Equatable, Sendable {
    /// One package manager's updates, or every update (nil): `menuUpdate(engine:)`.
    case update(EngineID?)
    case checkNow
    /// "Refresh MacPorts…": the window first (the password sheet is in it), then `refreshMacPortsCatalogue()`.
    case refreshMacPorts
    /// Open BrewxPort, and Show while a run is going (the run panel is in the window).
    case openWindow
    /// Settings…, which the view opens with SwiftUI's `openSettings` (only a view has it).
    case openSettings
    case quit
}

/// One item of the menu bar menu.
public enum MenuBarItem: Equatable, Sendable {
    /// Text that can't be chosen.
    case text(String)
    case button(String, MenuBarAction, enabled: Bool = true)
    case divider
}

/// The menu bar menu, built from the model; the view only draws it.
///
/// The updates come first: "5 updates", then one "<Manager>  <n>  Update" per package manager with updates (in the
/// engine order), then Update All. An item ends with "…" when any update it runs needs the password (its run route,
/// as for automatic updates, so a Homebrew cask counts and a formula doesn't). While a run is going they give way to
/// "Updating… <step>" (or "Waiting for your password") and Show. Then when BrewxPort last checked and will check
/// next, Check Now, Refresh MacPorts…
/// (once MacPorts was found and works), Open BrewxPort, Settings… and Quit.
@MainActor public enum MenuBarItems {
    public static func make(model: BrewxPortAppModel, timeZone: TimeZone = .current) -> [MenuBarItem] {
        var items = updateItems(model)
        items.append(.divider)
        items.append(.text(timesText(model.background, timeZone: timeZone)))
        items.append(.button("Check Now", .checkNow, enabled: model.background.state != .checking))
        if model.showsRefreshMacPorts {
            items.append(.button("Refresh MacPorts…", .refreshMacPorts, enabled: model.canRefreshMacPorts))
        }
        items.append(.divider)
        items.append(.button("Open BrewxPort", .openWindow))
        items.append(.button("Settings…", .openSettings))
        items.append(.button(model.quitTitle, .quit))
        return items
    }

    /// Settings… is opened by the view (`MenuBarContent`), so it never comes here.
    public static func perform(_ action: MenuBarAction, model: BrewxPortAppModel) {
        switch action {
        case .update(let engine):
            model.menuUpdate(engine: engine)
        case .checkNow:
            // The task holds the updater, not the model: a check can wait a long time (for a run's end).
            let background = model.background!
            Task { await background.checkNow() }
        case .refreshMacPorts:
            guard model.canRefreshMacPorts else { return }
            model.openMainWindow?()
            model.refreshMacPortsCatalogue()
        case .openWindow:
            model.openMainWindow?()
        case .openSettings:
            break
        case .quit:
            quit(model: model)
        }
    }

    /// Quit BrewxPort, from the menu bar menu or ⌘Q: the usual way, so a run in progress still asks first. AppKit
    /// doesn't quit while a sheet is on the window, so the one-time sheet goes first (and BrewxPort quits once it
    /// has), and any other sheet comes forward for an answer (`prepareToQuit`).
    public static func quit(model: BrewxPortAppModel?) {
        guard let model, model.showingBackgroundIntro else {
            model?.prepareToQuit()
            NSApp.terminate(nil)
            return
        }
        model.prepareToQuit()
        Task { @MainActor in
            // The sheet takes a moment to go; give it up to a second.
            var tries = 0
            while tries < 20, NSApp.windows.contains(where: { $0.attachedSheet != nil }) {
                tries += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
            NSApp.terminate(nil)
        }
    }

    // MARK: Updates

    private static func updateItems(_ model: BrewxPortAppModel) -> [MenuBarItem] {
        if model.run.isRunning { return [.text(runningText(model.run)), .button("Show", .openWindow)] }
        // Each request is planned once per build: per manager, then Update All from those answers.
        let byEngine = Dictionary(grouping: model.updates.updateAllRequests(), by: \.package.id.engine)
        let managers = model.engineOrder.compactMap { engine -> (engine: EngineID, count: Int, password: Bool)? in
            guard let requests = byEngine[engine] else { return nil }
            return (engine, requests.count, !requests.allSatisfy(model.background.isPasswordFree))
        }
        let total = managers.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [.text(emptyText(model.updates))] }
        let enabled = model.canMenuUpdate
        var items: [MenuBarItem] = [.text(total == 1 ? "1 update" : "\(total) updates")]
        for manager in managers {
            let title = "\(manager.engine.displayName)  \(manager.count)  Update" + (manager.password ? "…" : "")
            items.append(.button(title, .update(manager.engine), enabled: enabled))
        }
        let anyPassword = managers.contains { $0.password }
        items.append(.button("Update All" + (anyPassword ? "…" : ""), .update(nil), enabled: enabled))
        return items
    }

    /// Never "up to date" while the answers are still coming, or when a manager couldn't be checked. Otherwise Updates'
    /// own empty page decides (`UpdatesModel.emptyTitle`): "Nothing else to update" when some packages couldn't be
    /// looked up (R6, naming their managers) or updates are held back, "Everything is up to date" only when neither.
    private static func emptyText(_ updates: UpdatesModel) -> String {
        let list = updates.list
        if list.loading { return "Checking for updates…" }
        let failed = list.order.filter(list.failedEngines.contains).map(\.displayName)
        if !failed.isEmpty { return "No updates found. Couldn't check \(failed.joined(separator: ", "))" }
        let partly = list.order.filter { list.unchecked[$0].map { !$0.isEmpty } ?? false }
        guard !partly.isEmpty else { return updates.emptyTitle }
        let noun = partly.allSatisfy(\.isLanguage) ? "tools" : "packages"
        return updates.emptyTitle + ". Some " + RuntimeHolds.list(partly.map(\.displayName)) + " \(noun) couldn't be "
            + "checked"
    }

    /// "Updating… Homebrew: jq, wget": the step that's running, or just "Updating…" before one starts (the helper
    /// check, the password). A run that isn't only updates (an install from the window, say) says "Running…". A run
    /// nobody clicked for whose password sheet waits for BrewxPort to be active says "Waiting for your password".
    private static func runningText(_ run: RunController) -> String {
        if run.passwordWaitsForFocus { return RunController.waitingForPassword }
        let verb = run.steps.allSatisfy { $0.operation == .upgrade } ? "Updating…" : "Running…"
        guard let step = run.steps.first(where: { $0.state == .running }) else { return verb }
        return "\(verb) \(step.title)"
    }

    // MARK: Times

    /// "Checked 10:42. Next check 22:42", "Not checked yet. Next check 22:42", or without the next check when none
    /// is scheduled (checks off, or the demo).
    static func timesText(_ background: BackgroundUpdater, timeZone: TimeZone) -> String {
        let now = background.now()
        let checked = background.lastChecked.map { "Checked \(time($0, now: now, timeZone: timeZone))" }
            ?? "Not checked yet"
        guard let next = background.nextCheck else { return checked }
        return "\(checked). Next check \(time(next, now: now, timeZone: timeZone))"
    }

    /// 24-hour "HH:mm" for today; "tomorrow HH:mm" and "yesterday HH:mm"; "d MMM HH:mm" further off.
    static func time(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day
        switch days {
        case 0: return clock
        case 1: return "tomorrow \(clock)"
        case -1: return "yesterday \(clock)"
        default:
            formatter.dateFormat = "d MMM HH:mm"
            return formatter.string(from: date)
        }
    }
}
