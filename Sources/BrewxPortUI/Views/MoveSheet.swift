import BrewxPortCore
import SwiftUI

/// The move preview's words, kept apart from the view so they can be tested.
public enum MoveSheetText {
    public static let checking = "Checking…"

    public static func title(_ plan: MovePlan) -> String {
        "Move \(plan.picked.displayName) to \(plan.target.displayName)"
    }

    public static func movesTo(_ plan: MovePlan) -> String { "Moves to \(plan.target.displayName)" }

    public static func direction(_ plan: MovePlan) -> String {
        "\(plan.picked.id.engine.displayName) → \(plan.target.displayName)"
    }

    /// A row's name, with "(needs it)" on a dependent of the picked package.
    public static func name(_ item: MoveItem, in plan: MovePlan) -> String {
        item.old.id == plan.picked.id ? item.old.displayName : "\(item.old.displayName) (needs it)"
    }

    /// "old → new": the source's installed version, then the target's (installed there, or the one it will install).
    public static func versions(_ item: MoveItem) -> String {
        let new = item.needsInstall ? item.new.latestVersion : item.new.installedVersion ?? item.new.latestVersion
        return "\(item.old.installedVersion ?? "–") → \(new ?? "–")"
    }

    /// One package that stays. Not on the target: says the picked package's old copy stays for it (or, for the
    /// picked package itself, that it can't move). Any other reason is shown as it is.
    public static func cantMoveLine(_ entry: CantMove, in plan: MovePlan) -> String {
        let target = plan.target.displayName
        guard isNotOnTarget(entry, plan) else { return "\(entry.name): \(entry.reason)" }
        if entry.name == plan.picked.id.name.lowercased() {
            return "\(plan.picked.displayName) isn't on \(target), so it can't move."
        }
        return "\(entry.name) isn't on \(target), so \(keptCopy(plan))"
    }

    /// Every line about what stays, in order. When the picked package still moves but its old copy is kept, the sheet
    /// says so exactly once: in the first not-found line (later ones just say "<name> isn't on <Target>."), or as a
    /// line of its own after the reasons when none of them is a not-found one.
    public static func cantMoveLines(_ plan: MovePlan) -> [String] {
        let keptSaid = plan.keepPicked && !plan.moving.isEmpty
        var said = false
        var lines: [String] = []
        for entry in plan.cantMove {
            let picked = entry.name == plan.picked.id.name.lowercased()
            if isNotOnTarget(entry, plan), !picked, said {
                lines.append("\(entry.name) isn't on \(plan.target.displayName).")
                continue
            }
            if isNotOnTarget(entry, plan), !picked { said = true }
            lines.append(cantMoveLine(entry, in: plan))
        }
        if keptSaid, !said { lines.append(keptCopy(plan)) }
        return lines
    }

    /// "<picked>'s <Source> copy stays."
    static func keptCopy(_ plan: MovePlan) -> String {
        "\(plan.picked.displayName)'s \(plan.picked.id.engine.displayName) copy stays."
    }

    private static func isNotOnTarget(_ entry: CantMove, _ plan: MovePlan) -> Bool {
        let target = plan.target.displayName
        return entry.reason == "not on \(target)" || entry.reason == "couldn't find it on \(target)"
    }

    public static func leftoversToggle(_ plan: MovePlan) -> String {
        "Also remove leftovers from \(plan.picked.id.engine.displayName)"
    }

    public static func leftoverNames(_ leftovers: [Package]) -> String {
        let names = leftovers.map(\.displayName).joined(separator: ", ")
        return names + (leftovers.count == 1 ? " (nothing else uses it)" : " (nothing else uses them)")
    }

    /// Only MacPorts needs the password; one run asks at most once.
    public static func passwordLine(_ plan: MovePlan) -> String {
        let source = plan.picked.id.engine
        if source == .macports || plan.target == .macports { return "You'll be asked for your password once." }
        return "\(source.displayName) and \(plan.target.displayName) don't need your password."
    }

    public static func moveButton(count: Int) -> String {
        count == 1 ? "Move 1 package" : "Move \(count) packages"
    }

    // MARK: The PATH warning's fix

    public static let addToPath = "Add to PATH"
    public static func addsLine(to file: String) -> String { "Adds this line to \(file):" }
    /// Above the line when BrewxPort only offers it to copy: names the file the person probably uses, when known.
    public static func copyCaption(hint: String?) -> String {
        hint.map { "Add this line to \($0):" } ?? "Add this line to your shell's startup file:"
    }
    public static let copy = "Copy"
    public static let notInDemo = "Not available in demo mode"

    /// What replaces the warning once "Add to PATH" worked.
    public static func pathFixDone(_ outcome: ShellPathEditor.Outcome, _ plan: MovePlan) -> String {
        switch outcome {
        case .added(let file): return "Added to \(file). Open a new Terminal window to use \(plan.picked.displayName)."
        case .alreadyPresent(let file): return "Already in \(file)"
        }
    }

    public static func pathFixFailure(_ failure: ShellPathEditor.Failure) -> String {
        switch failure {
        case .unknownDirectory: return "BrewxPort only adds Homebrew, nanobrew and MacPorts folders to your PATH."
        case .copyOnly: return "BrewxPort can't change your shell's startup file. Copy the line instead."
        case .notARegularFile(let file): return "\(file) isn't a regular file, so BrewxPort didn't change it."
        case .notYours(let file): return "\(file) belongs to another user, so BrewxPort didn't change it."
        case .couldNotWrite(let file, let reason): return "BrewxPort couldn't change \(file): \(reason)."
        }
    }
}

/// The "Move to…" preview: what moves (old → new version), what can't and why, the leftovers toggle, the PATH
/// warning and the password line, then Cancel and Move. While the facts are gathered it shows a spinner; a failed
/// check shows why and Close. When the picked package itself can't move there's nothing to confirm, only Close.
struct MoveSheet: View {
    let model: MoveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.state {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(MoveSheetText.checking)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
                buttons(cancel: "Cancel", confirm: nil)
            case .failed(let message):
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                buttons(cancel: "Close", confirm: nil)
            case .ready(let plan):
                ready(plan)
            case .hidden, .running:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private func ready(_ plan: MovePlan) -> some View {
        Text(MoveSheetText.title(plan))
            .font(.headline)
        ForEach(MoveSheetText.cantMoveLines(plan), id: \.self) { line in
            Label(line, systemImage: "info.circle")
                .fixedSize(horizontal: false, vertical: true)
        }
        if !plan.moving.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text(MoveSheetText.movesTo(plan))
                    Text(MoveSheetText.direction(plan))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                ForEach(plan.moving, id: \.old.id) { item in
                    GridRow {
                        Text(MoveSheetText.name(item, in: plan))
                        Text(MoveSheetText.versions(item))
                            .monospacedDigit()
                    }
                }
            }
            if !plan.leftovers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(MoveSheetText.leftoversToggle(plan), isOn: Binding(
                        get: { plan.removeLeftovers },
                        set: { model.setRemoveLeftovers($0) }))
                    Text(MoveSheetText.leftoverNames(plan.leftovers))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
            if let warning = plan.pathWarning {
                pathWarning(warning, plan)
            }
            Text(MoveSheetText.passwordLine(plan))
                .foregroundStyle(.secondary)
        }
        if plan.moving.isEmpty {
            buttons(cancel: "Close", confirm: nil)
        } else {
            buttons(cancel: "Cancel", confirm: MoveSheetText.moveButton(count: plan.moving.count))
        }
    }

    /// The PATH warning and its opt-in fix: the line and the file it goes into, then "Add to PATH" (zsh and bash), or
    /// the line with Copy for any other shell. Nothing is written until the button is clicked. After it worked, the
    /// warning says so instead.
    @ViewBuilder private func pathWarning(_ warning: String, _ plan: MovePlan) -> some View {
        if case .done(let outcome) = model.pathFix {
            Label(MoveSheetText.pathFixDone(outcome, plan), systemImage: "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                if let line = model.pathLine {
                    let caption = switch model.pathOffer {
                    case .append(let target): MoveSheetText.addsLine(to: target.file)
                    case .copyOnly(let hint): MoveSheetText.copyCaption(hint: hint)
                    }
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        switch model.pathOffer {
                        case .append:
                            Button(MoveSheetText.addToPath) { model.addToPath() }
                                .disabled(model.isDemo)
                                .help(model.isDemo ? MoveSheetText.notInDemo : caption + " " + line)
                        case .copyOnly:
                            Button(MoveSheetText.copy) { model.copyPathLine() }
                        }
                        if case .failed(let message) = model.pathFix {
                            Text(message)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Cancel (or Close) and the Move button when there's something to confirm.
    private func buttons(cancel: String, confirm: String?) -> some View {
        HStack {
            Spacer()
            Button(cancel, role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            if let confirm {
                Button(confirm) { model.confirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
