import Foundation

/// Mac App Store apps, driven through `mas` (7.x) and its `--json` output (one JSON object per line).
public struct MasEngine: Engine {
    public let id: EngineID = .mas
    public let capabilities: EngineCapabilities = [.jsonOutput]

    private let runner: CommandRunning
    private let cache: ExecutableCache
    private var executable: URL? { cache.current }

    public var executableURL: URL? { executable }

    public init(runner: CommandRunning, executable: URL?) {
        self.runner = runner
        self.cache = ExecutableCache(locate: { executable })
    }

    public init(runner: CommandRunning, locate: @escaping @Sendable () -> URL?) {
        self.runner = runner
        self.cache = ExecutableCache(locate: locate)
    }

    // MARK: detect

    public func detect() async -> EngineStatus {
        await detectStatus(runner: runner, executable: cache.relocate(), arguments: ["version"]) { stdout in
            guard let first = stdout.split(whereSeparator: \.isNewline).first else { return nil }
            let version = first.trimmingCharacters(in: .whitespaces)
            return version.isEmpty ? nil : version
        }
    }

    // MARK: records

    /// One line of `mas search|list|outdated --json`. Only the fields BrewxPort uses are decoded.
    private struct Record: Decodable {
        let adamID: Int?
        let name: String?
        let trackName: String?
        let censoredName: String?
        let version: String?
        /// Only `mas outdated --json` has this (mas 7 `OutdatedApp.newVersion`); there `version` is the installed one.
        let newVersion: String?

        /// The captured mas 7 output has `name`; older fields are fallbacks.
        func displayName(adamID: Int) -> String { name ?? trackName ?? censoredName ?? String(adamID) }
    }

    private static let noMatchPrefix = "Error: No apps found in the App Store for search term:"

    /// A record that has an App Store id. Records without one can't be addressed and are dropped by `runRecords`.
    private struct Identified {
        let adamID: Int
        let record: Record
    }

    private func runRecords(_ args: [String], noMatchIsEmpty: Bool = false) async throws -> [Identified] {
        let exe = try requireExecutable()
        let result = try await runner.run(exe, args)
        if noMatchIsEmpty, result.exitCode == 1,
           result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.noMatchPrefix) {
            return []
        }
        guard result.exitCode == 0 else {
            throw failure("mas \(args.joined(separator: " ")) failed", result)
        }
        let decoder = JSONDecoder()
        var records: [Identified] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            do {
                let record = try decoder.decode(Record.self, from: Data(text.utf8))
                // Can't be addressed without an id: skip it, don't fail the listing.
                guard let adamID = record.adamID else { continue }
                records.append(Identified(adamID: adamID, record: record))
            } catch {
                throw EngineError(engine: .mas, message: "Couldn't read mas's JSON output: \(error.localizedDescription)")
            }
        }
        return records
    }

    private func package(_ r: Identified, installed: String? = nil, latest: String? = nil) -> Package {
        Package(id: PackageRef(engine: .mas, kind: .app, name: String(r.adamID)),
                displayName: r.record.displayName(adamID: r.adamID),
                installedVersion: installed,
                latestVersion: latest)
    }

    // MARK: search / installed / outdated

    public func search(_ query: String) async throws -> [Package] {
        let args = try searchArguments(["search", "--json"], query: query, engine: .mas)
        return try await runRecords(args, noMatchIsEmpty: true).map { package($0, latest: $0.record.version) }
    }

    public func listInstalled() async throws -> [Package] {
        // Every App Store app was picked by someone; none comes in as a dependency.
        try await runRecords(["list", "--json"]).map {
            var app = package($0, installed: $0.record.version)
            app.installedOnRequest = true
            return app
        }
    }

    public func listOutdated() async throws -> [Package] {
        // mas 7 source (OutdatedApp.swift): the installed app's JSON plus `newVersion`, so `version` is the
        // installed version. The real capture is empty (nothing outdated), so this mapping follows the source.
        try await runRecords(["outdated", "--json"]).map {
            package($0, installed: $0.record.version, latest: $0.record.newVersion)
        }
    }

    // MARK: info

    private struct InfoRecord: Decodable {
        let name: String?
        let trackName: String?
        let censoredName: String?
        let version: String?
        let appStorePageURL: String?
        let description: String?
    }

    /// `mas info --json <id>` prints one JSON object. The "homepage" is the App Store page; the summary is the first
    /// paragraph of the store description.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard ref.engine == .mas else {
            throw EngineError(engine: .mas, message: "Package belongs to a different engine")
        }
        let id = try packageNameArguments([ref], engine: .mas)[0]
        guard id.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) else {
            throw EngineError(engine: .mas, message: "Invalid App Store id: \(id)")
        }
        let exe = try requireExecutable()
        let args = ["info", "--json", id]
        let result = try await runner.run(exe, args)
        guard result.exitCode == 0 else {
            throw failure("mas \(args.joined(separator: " ")) failed", result)
        }
        let record: InfoRecord
        do {
            record = try JSONDecoder().decode(InfoRecord.self, from: Data(result.stdout.utf8))
        } catch {
            throw EngineError(engine: .mas, message: "Couldn't read mas's JSON output: \(error.localizedDescription)")
        }
        // An object with no name and no version isn't an app record (`{}`): don't hand back empty details.
        guard nonBlank(record.name ?? record.trackName ?? record.censoredName) != nil, nonBlank(record.version) != nil else {
            throw EngineError(engine: .mas, message: "mas had no information for app \(id)")
        }
        let firstParagraph = record.description?
            .components(separatedBy: "\n").first(where: { nonBlank($0) != nil })
        return PackageDetails(ref: ref, summary: nonBlank(firstParagraph), homepage: webURL(record.appStorePageURL),
                              latestVersion: nonBlank(record.version))
    }

    // MARK: commands

    /// `mas help` documents install, get, update (alias upgrade) and uninstall as requiring root; an end-to-end
    /// signed-in root run is still pending. See private/spikes/2026-11-sudo-askpass.md (mas section).
    /// Run mas as `sudo -A mas …` from the user's session (it switches back to SUDO_UID), not directly as root
    /// from a daemon.
    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege {
        .always
    }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        guard refs.allSatisfy({ $0.engine == .mas }) else {
            throw EngineError(engine: .mas, message: "Package belongs to a different engine")
        }
        guard options.version == nil else {
            throw EngineError(engine: .mas, message: "mas can't install a specific version")
        }
        guard options.variants.isEmpty else {
            throw EngineError(engine: .mas, message: "mas has no variants")
        }
        guard options.extraArgs.isEmpty else {
            throw EngineError(engine: .mas, message: "mas root commands take no extra arguments")
        }
        let ids = try packageNameArguments(refs, engine: .mas)
        for id in ids where !id.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
            throw EngineError(engine: .mas, message: "Invalid App Store id: \(id)")
        }
        let exe = try requireExecutable()
        let verb: String
        switch op {
        case .install: verb = "install"
        case .upgrade: verb = "upgrade"
        case .remove: verb = "uninstall"
        }
        return CommandSpec(executable: exe, arguments: [verb] + ids, needsRoot: true)
    }

    // MARK: helpers

    private func requireExecutable() throws -> URL {
        guard let executable else {
            throw EngineError(engine: .mas, message: "mas isn't installed")
        }
        return executable
    }

    private func failure(_ what: String, _ result: CommandResult) -> EngineError {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(err.prefix(300))
        let suffix = excerpt.isEmpty ? "" : ": \(excerpt)"
        return EngineError(engine: .mas, message: "\(what) (exit \(result.exitCode))\(suffix)")
    }
}
