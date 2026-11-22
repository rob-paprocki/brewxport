import Foundation
import BrewxPortCore

/// The run log the window shows, built from `RunEvent`s.
public struct RunLog: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
        public let isError: Bool
    }

    public private(set) var lines: [Line] = []
    /// The step that started and hasn't finished yet.
    public private(set) var openStep: Int?
    private let titles: [String]
    private let operations: [PackageOperation]
    /// Which steps are check steps. Their titles say what they do, so they're logged without a verb.
    private let checks: [Bool]

    /// Every step is worded as an update.
    public init(titles: [String] = []) {
        self.titles = titles
        self.operations = titles.map { _ in .upgrade }
        self.checks = titles.map { _ in false }
    }

    /// Each step is worded by its operation: "Installing", "Updating" or "Removing". A check step is logged by its
    /// title alone.
    public init(steps: [RunStep]) {
        self.titles = steps.map(\.title)
        self.operations = steps.map(\.operation)
        self.checks = steps.map { $0.verifyInstalled != nil }
    }

    public mutating func note(_ text: String, isError: Bool = false) {
        lines.append(Line(id: lines.count, text: text, isError: isError))
    }

    private func title(_ index: Int) -> String {
        titles.indices.contains(index) ? titles[index] : "Step \(index + 1)"
    }

    private func verb(_ index: Int) -> String {
        switch operations.indices.contains(index) ? operations[index] : .upgrade {
        case .install: "Installing"
        case .upgrade: "Updating"
        case .remove: "Removing"
        case .markRequested, .markDependency: "Marking"
        }
    }

    public mutating func apply(_ event: RunEvent) {
        switch event {
        case .needsPassword:
            note("Waiting for the administrator password.")
        case .passwordRejected:
            note("That password didn't work. Nothing was changed.", isError: true)
        case .privilegeUnavailable(let reason):
            note(reason, isError: true)
            note("Nothing was changed.", isError: true)
        case .started(let index):
            openStep = index
            let isCheck = checks.indices.contains(index) && checks[index]
            note(isCheck ? title(index) : "\(verb(index)) \(title(index))")
        case .output(_, .stdout(let line)):
            note(line)
        case .output(_, .stderr(let line)):
            note(line, isError: true)
        case .finished(let index, let code):
            if openStep == index { openStep = nil }
            if code == 0 {
                note("Finished \(title(index)).")
            } else {
                note("\(title(index)) failed (exit code \(code)).", isError: true)
            }
        case .cancelled:
            // A step that started and never finished was stopped part way.
            if let open = openStep {
                note("Stopped \(title(open)) before it finished.", isError: true)
                openStep = nil
            }
            note("Cancelled. Nothing more will run.")
        case .done:
            note("Done.")
        }
    }
}
