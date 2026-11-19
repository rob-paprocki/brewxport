import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// The symbol for each step state. Running has none: the panel shows a spinner there.
public enum RunStepSymbol {
    public static func name(_ state: StepState) -> String? {
        switch state {
        case .waiting: "circle"
        case .running: nil
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .skipped: "arrow.uturn.forward"
        }
    }

    /// What VoiceOver says for the symbol (or the spinner), since the colour and shape alone say nothing.
    public static func label(_ state: StepState) -> String {
        switch state {
        case .waiting: "Waiting"
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .skipped: "Skipped"
        }
    }
}

/// The bottom panel: the run's steps, its log behind a disclosure, and Cancel (or Close once it's over).
struct RunPanel: View {
    @Bindable var run: RunController
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(run.headline).font(.headline)
                if run.isRunning { ProgressView().controlSize(.small).accessibilityLabel("Running") }
                Spacer()
                if run.isRunning {
                    Button("Cancel", action: run.cancel)
                } else {
                    Button("Close", action: run.dismissPanel)
                }
            }
            ForEach(Array(run.problems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if run.passwordRejected {
                Label("That password didn't work", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if let problem = run.privilegeProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(run.steps) { step in
                        HStack(spacing: 6) {
                            stateMark(step.state)
                            Text(step.title).lineLimit(1).truncationMode(.middle)
                            if case .failed(let code) = step.state {
                                Text("exit code \(code)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            DisclosureGroup("Log", isExpanded: $showLog) {
                logView
            }
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder private func stateMark(_ state: StepState) -> some View {
        if let name = RunStepSymbol.name(state) {
            Image(systemName: name)
                .foregroundStyle(color(state))
                .frame(width: 16)
                .accessibilityLabel(RunStepSymbol.label(state))
        } else {
            ProgressView().controlSize(.mini).frame(width: 16)
                .accessibilityLabel(RunStepSymbol.label(state))
        }
    }

    private func color(_ state: StepState) -> Color {
        switch state {
        case .succeeded: .green
        case .failed: .red
        case .stopped: .orange
        case .waiting, .running, .skipped: .secondary
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(run.log.lines) { line in
                        // An error line has a symbol as well as the red, so it reads without colour too.
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if line.isError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .accessibilityLabel("Error")
                            }
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .foregroundStyle(line.isError ? Color.red : Color.primary)
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 100, maxHeight: 200)
            .onChange(of: run.log.lines.count) {
                if let last = run.log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
