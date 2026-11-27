import Foundation
import BrewxPortCore

/// `--demo-states`: the states Plan 9 added that the captures alone can't show, layered on the lists the demo read
/// from them, so each can be looked at in the window. None of it is a capture. Values come from the captures where
/// they have one, and what's invented is named here:
///
/// - RubyGems installs into Ruby's own gem folder, as with rbenv, asdf or mise (`FixtureRunner.rubySharesGemFolder`;
///   the captured Homebrew Ruby doesn't). The real engine then lists Ruby's bundled gems with executables as tools that
///   came with Ruby (R19) and looks up the ones `gem outdated` names. Only thor's and lolcat's compact index answers
///   were captured, so the others are tools its check couldn't look up ("4 tools couldn't be checked").
/// - Except `rubysGem`, offered at the version the captured `gem outdated` names and held from automatic updates
///   because it came with Ruby. Invented: that its lookup answered.
/// - Cargo's updates are held for the Rust their new version needs, from the captured crates.io index (ripgrep 16.0.0
///   needs Rust 1.96), held from every update. Invented: a Rust older than that beside cargo (the captured one is
///   1.100.0, which Cargo's row in the sidebar still shows).
/// - Homebrew's node is installed at the captured `node --version` and has an update to `nodeUpdate`. Invented: that
///   update. The app then holds it back for npm's tools itself (`RuntimeHolds`), as it would on a real Mac.
///
/// Nothing here throws: a capture it can't read leaves that state out.
enum DemoStates {
    /// node's next major version. Invented: no capture has a newer node.
    static let nodeUpdate = "27.0.0"
    /// The bundled gem shown as an update that came with Ruby.
    static let rubysGem = "rake"

    static func apply(installed: inout [EngineID: [Package]], outdated: inout [EngineID: OutdatedReport],
                      fixtures: URL) {
        holdForRust(&outdated, fixtures: fixtures)
        offerRubysGem(&outdated, fixtures: fixtures)
        addHomebrewNode(&installed, &outdated, fixtures: fixtures)
    }

    /// Moves each Cargo update whose new version names the Rust it needs (in its captured index file) from the updates
    /// to the holds, as `CargoEngine` does when the Rust beside cargo is older.
    private static func holdForRust(_ outdated: inout [EngineID: OutdatedReport], fixtures: URL) {
        guard var report = outdated[.cargo] else { return }
        for row in report.packages {
            guard let latest = row.latestVersion,
                  let needs = rustVersion(crate: row.id.name, version: latest, fixtures: fixtures) else { continue }
            report.packages.removeAll { $0.id == row.id }
            report.held.append(HeldUpdate(package: row, hold: UpdateHold(reason: CargoEngine.needsRustReason(needs),
                                                                         blocksAutomatic: true, blocksManual: true)))
        }
        outdated[.cargo] = report
    }

    /// The Rust `version` of `crate` needs, from its line in the captured crates.io index (`cargo/index-<crate>.txt`).
    static func rustVersion(crate: String, version: String, fixtures: URL) -> String? {
        guard let text = read("cargo/index-\(crate).txt", fixtures) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["vers"] as? String == version else { continue }
            return entry["rust_version"] as? String
        }
        return nil
    }

    /// Offers `rubysGem` as RubyGems' check would once its lookup answered: in the updates and held from automatic
    /// ones (`GemEngine.shippedWithRubyHold`), no longer among the tools it couldn't check.
    private static func offerRubysGem(_ outdated: inout [EngineID: OutdatedReport], fixtures: URL) {
        guard var report = outdated[.gem], report.unchecked.reasons[rubysGem] != nil,
              let versions = gemOutdated(rubysGem, fixtures: fixtures) else { return }
        let row = Package(id: PackageRef(engine: .gem, kind: .tool, name: rubysGem), displayName: rubysGem,
                          installedVersion: versions.installed, latestVersion: versions.latest)
        report.packages = (report.packages + [row]).sorted { $0.id.name < $1.id.name }
        report.held.append(HeldUpdate(package: row, hold: GemEngine.shippedWithRubyHold))
        var reasons = report.unchecked.reasons
        reasons[rubysGem] = nil
        report.unchecked = UncheckedPackages(reasons: reasons, unnamed: report.unchecked.unnamed,
                                             note: report.unchecked.note)
        outdated[.gem] = report
    }

    /// `name`'s versions in the captured `gem outdated` (`rake (13.3.1 < 13.4.2)`).
    static func gemOutdated(_ name: String, fixtures: URL) -> (installed: String, latest: String)? {
        guard let text = read("gem/outdated.txt", fixtures) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(name + " (") && line.hasSuffix(")") {
            let versions = line.dropFirst(name.count + 2).dropLast().components(separatedBy: " < ")
            guard versions.count == 2, !versions[0].isEmpty, !versions[1].isEmpty else { return nil }
            return (versions[0], versions[1])
        }
        return nil
    }

    /// Homebrew's node, asked for, at the captured `node --version` (the npm captures' node), with `nodeUpdate`.
    private static func addHomebrewNode(_ installed: inout [EngineID: [Package]],
                                        _ outdated: inout [EngineID: OutdatedReport], fixtures: URL) {
        guard var version = read("npm/node-version.txt", fixtures)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return }
        if version.hasPrefix("v") { version.removeFirst() }
        guard !version.isEmpty else { return }
        let row = Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "node"), displayName: "node",
                          installedVersion: version, installedOnRequest: true)
        installed[.homebrew] = ((installed[.homebrew] ?? []) + [row]).sorted { $0.id.name < $1.id.name }
        var update = row
        update.latestVersion = nodeUpdate
        var report = outdated[.homebrew] ?? OutdatedReport(packages: [])
        report.packages = (report.packages + [update]).sorted { $0.id.name < $1.id.name }
        outdated[.homebrew] = report
    }

    private static func read(_ relative: String, _ fixtures: URL) -> String? {
        FileManager.default.contents(atPath: fixtures.appendingPathComponent(relative).path)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
