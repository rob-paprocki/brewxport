import AppKit
import SwiftUI

/// BrewxPort > Settings… (⌘,): when to check for updates, what to do with them, notifications and Open at login.
/// `SettingsModel` holds what each one does; this only draws it.
///
/// While it's open it counts as one of BrewxPort's windows for the Dock icon (`settingsWindowShowing`). Each time it
/// appears, and whenever BrewxPort becomes active while it's open, the Open at login switch is read again from the
/// system, so a change made in System Settings shows.
public struct SettingsView: View {
    let model: BrewxPortAppModel
    @State private var form: SettingsModel

    public init(model: BrewxPortAppModel) {
        self.model = model
        _form = State(initialValue: SettingsModel(model: model))
    }

    public var body: some View {
        @Bindable var form = form
        Form {
            Section {
                Picker(SettingsModel.intervalLabel, selection: $form.interval) {
                    ForEach(CheckInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(SettingsModel.modeLabel, selection: $form.mode) {
                    ForEach(AutoUpdateMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if let note = form.standardAccountNote { Self.note(note) }
            }
            Section {
                Toggle(SettingsModel.notificationsLabel, isOn: Binding(
                    get: { form.settings.notificationsOn },
                    set: { on in Task { await form.setNotifications(on) } }))
                if let problem = form.notificationsProblem { Self.note(problem) }
                Toggle(SettingsModel.openAtLoginLabel, isOn: Binding(
                    get: { form.settings.openAtLogin },
                    set: { form.setOpenAtLogin($0) }))
                if let note = form.loginItemNote { Self.note(note) }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.settingsWindowShowing = true
            form.refresh()
        }
        .onDisappear { model.settingsWindowShowing = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            form.refresh()
        }
    }

    private static func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
