import SwiftUI

/// The one-time sheet's words.
enum BackgroundIntro {
    static let title = "BrewxPort now checks for updates"

    /// "It checks every 12 hours and stays in the menu bar…", with the interval as it is now (the person can change
    /// it in Settings while the sheet is up).
    static func body(for interval: CheckInterval) -> String {
        guard interval != .never else { return "Update checks are off. You can turn them on in Settings." }
        return "It checks \(interval.title.lowercased()) and stays in the menu bar when you close its window. "
            + "You can change this in Settings."
    }
}

/// "BrewxPort now checks for updates", shown once on the window (`BrewxPortAppModel.showingBackgroundIntro`). Its two
/// switches are Settings' own: Show notifications (on unless switched off) and Open BrewxPort at login (off unless
/// switched on, which registers it at once). Done, Settings… and Esc all close it the same way, keeping what the
/// switches show (`closeBackgroundIntro()`).
struct BackgroundIntroSheet: View {
    let model: BrewxPortAppModel
    @State private var form: SettingsModel
    @Environment(\.openSettings) private var openSettings

    init(model: BrewxPortAppModel) {
        self.model = model
        _form = State(initialValue: SettingsModel(model: model))
    }

    var body: some View {
        @Bindable var settings = model.background.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(BackgroundIntro.title).font(.title2.bold())
                Text(BackgroundIntro.body(for: settings.interval))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                // macOS is asked for permission when the sheet closes, if they're still on.
                switchRow(SettingsModel.notificationsLabel, isOn: $settings.notificationsOn)
                switchRow(SettingsModel.openAtLoginLabel,
                          isOn: Binding(get: { settings.openAtLogin }, set: { form.setOpenAtLogin($0) }))
                if let note = form.loginItemNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Settings…") {
                    model.closeBackgroundIntro()
                    openSettings()
                }
                Button("Done", action: model.closeBackgroundIntro).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}
