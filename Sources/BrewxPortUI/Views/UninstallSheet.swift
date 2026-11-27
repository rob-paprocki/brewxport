import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// The uninstall sheet's words, kept apart from the view so they can be tested.
public enum UninstallSheetText {
    public static let checking = "Checking…"
    public static let cancel = "Cancel"
    public static let password = "You'll be asked for your password once."

    /// Every package that will be removed, ticked leftovers included, in section order.
    static func removed(_ plan: UninstallPlan) -> [Package] {
        plan.sections.flatMap { $0.picks + ($0.removeLeftovers ? $0.leftovers : []) }
    }

    /// "Uninstall wget?" for one pick, "Uninstall 3 packages?" otherwise. Blocked picks aren't counted, except that
    /// when nothing can be removed and there was only one pick, the title still names it.
    public static func title(_ plan: UninstallPlan) -> String {
        let picks = plan.sections.flatMap(\.picks)
        if picks.count == 1 { return "Uninstall \(picks[0].displayName)?" }
        if picks.isEmpty {
            let blocked = plan.sections.flatMap(\.blocked)
            return blocked.count == 1 ? "Uninstall \(blocked[0].package.displayName)?" : "Uninstall packages?"
        }
        return "Uninstall \(picks.count) packages?"
    }

    /// "wget 1.25.0", or just the name when no version is known.
    public static func pickLine(_ package: Package) -> String {
        package.installedVersion.map { "\(package.displayName) \($0)" } ?? package.displayName
    }

    public static func blockedLine(_ blocked: BlockedPick) -> String {
        "\(blocked.package.displayName) stays: \(blocked.reason)"
    }

    public static func leftoversToggle(_ section: UninstallSection) -> String {
        "Also remove leftovers from \(section.engine.displayName)"
    }

    public static func leftoverNames(_ leftovers: [Package]) -> String {
        let names = leftovers.map(\.displayName).joined(separator: ", ")
        return names + (leftovers.count == 1 ? " (nothing else uses it)" : " (nothing else uses them)")
    }

    /// The password line when any of `steps` (the steps the sheet would run) doesn't run as you: MacPorts, the Mac App
    /// Store and Homebrew casks. The same test the run itself makes before it asks.
    public static func passwordLine(_ steps: [RunStep]) -> String? {
        steps.contains { RunRouting.route(for: $0) != .user } ? password : nil
    }

    public static let needsAdministrator = "Removing these needs an administrator account."

    /// The password line, or on a standard account (`isAdministrator == false`) the line saying those removals need
    /// an administrator, since the run refuses a standard account before it asks. A failed check (nil) goes ahead
    /// like the run does and gets the password line.
    public static func accountLine(_ steps: [RunStep], isAdministrator: Bool?) -> String? {
        guard let line = passwordLine(steps) else { return nil }
        return isAdministrator == false ? needsAdministrator : line
    }

    /// "Uninstall" for one package, "Uninstall 3 packages" for more.
    public static func uninstallButton(_ plan: UninstallPlan) -> String {
        uninstallButton(removing: removed(plan).count)
    }

    /// The button for `count` removals.
    public static func uninstallButton(removing count: Int) -> String {
        count > 1 ? "Uninstall \(count) packages" : "Uninstall"
    }

    public static func canUninstall(_ plan: UninstallPlan) -> Bool { !removed(plan).isEmpty }
}

/// The uninstall confirmation: per package manager the picks (with versions), what stays and why, the leftovers box,
/// and a note when leftovers couldn't be worked out. Then what removing a Python would break (pipx's and uv's tools). Then the password line when it applies (on a standard account, the
/// line saying those removals need an administrator, with their managers dimmed), Cancel and Uninstall.
struct UninstallSheet: View {
    /// The tallest the package list gets before it scrolls.
    static let listMaxHeight: CGFloat = 360

    let model: UninstallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.state {
            case .ready(let plan):
                ready(plan)
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(UninstallSheetText.checking)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                buttons(confirm: nil, enabled: false)
            case .hidden, .running:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private func ready(_ plan: UninstallPlan) -> some View {
        let confirmation = model.confirmation(for: plan)
        Text(UninstallSheetText.title(plan))
            .font(.headline)
        // A long list scrolls, so the title, the password line and the buttons always stay on screen. The list is as
        // tall as its contents up to the cap.
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(plan.sections, id: \.engine) { section in
                    // A manager this account can't remove anything from is shown dimmed and its box is off: the
                    // administrator line below says why.
                    let skipped = confirmation.skipped.contains(section.engine)
                    sectionView(section)
                        .disabled(skipped)
                        .opacity(skipped ? 0.5 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.listMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        if let warning = model.runtimeWarning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let line = confirmation.line {
            Text(line)
                .foregroundStyle(.secondary)
        }
        buttons(confirm: confirmation.button, enabled: confirmation.enabled)
    }

    @ViewBuilder private func sectionView(_ section: UninstallSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(section.picks, id: \.id) { pick in
                HStack {
                    Text(UninstallSheetText.pickLine(pick))
                    Spacer()
                    Text(section.engine.displayName)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(section.blocked, id: \.package.id) { blocked in
                Label(UninstallSheetText.blockedLine(blocked), systemImage: "info.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !section.leftovers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(UninstallSheetText.leftoversToggle(section), isOn: Binding(
                        get: { section.removeLeftovers },
                        set: { model.setRemoveLeftovers($0, engine: section.engine) }))
                    Text(UninstallSheetText.leftoverNames(section.leftovers))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            if let note = section.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(confirm: String?, enabled: Bool) -> some View {
        HStack {
            Spacer()
            Button(UninstallSheetText.cancel, role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            if let confirm {
                Button(confirm, role: .destructive) { model.confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!enabled)
            }
        }
    }
}
