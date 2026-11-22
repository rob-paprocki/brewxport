import Foundation

/// Facts about the Xcode Command Line Tools and how to find the installable update.
public enum CommandLineTools {
    public static let marker = "/Library/Developer/CommandLineTools/usr/bin/git"
    public static let placeholder = "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

    /// The highest-version "Command Line Tools" label in `softwareupdate -l` output, compared numerically.
    public static func label(fromSoftwareUpdateList text: String) -> String? {
        var best: (label: String, version: [Int])?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* Label:") else { continue }
            let label = trimmed.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
            guard label.contains("Command Line Tools") else { continue }
            let version = versionParts(of: label)
            if let current = best, !current.version.lexicographicallyPrecedes(version) { continue }
            best = (label, version)
        }
        return best?.label
    }

    /// The numbers after the last "-" (for example "16.4" gives [16, 4]).
    private static func versionParts(of label: String) -> [Int] {
        guard let dash = label.lastIndex(of: "-") else { return [] }
        return label[label.index(after: dash)...].split(separator: ".").compactMap { Int($0) }
    }
}
