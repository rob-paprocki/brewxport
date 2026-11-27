import Foundation

/// PyPI's JSON API (`https://pypi.org/pypi/<name>/json`) and the PEP 440 rules its answers are read with, for the
/// engines that drive Python tools (pipx and uv). Every request goes through the engine's `RegistryFetching`.
///
/// - PyPI has no search, so Discover looks up the exact project name (`search`), and details come from the project's
///   JSON (`details`).
/// - When a tool can't say itself which of its packages are outdated (an older pipx or uv), each project is looked up
///   here (`projects`), and `Project.newerVersion` picks its newest release that isn't yanked and fits the tool's
///   Python.
enum PyPI {
    /// Lookups at a time, for an outdated check.
    static let concurrentLookups = 4

    /// A project's JSON on PyPI, as much as BrewxPort uses.
    struct Project: Decodable, Sendable {
        struct Info: Decodable, Sendable {
            let name: String?
            /// The newest release by PEP 440, preferring ones not yanked and not pre-releases.
            let version: String?
            let summary: String?
            let homePage: String?
            /// The project's page on PyPI.
            let projectURL: String?
            let projectURLs: [String: String]?
            let requiresPython: String?
            let yanked: Bool?

            enum CodingKeys: String, CodingKey {
                case name, version, summary, yanked
                case homePage = "home_page"
                case projectURL = "project_url"
                case projectURLs = "project_urls"
                case requiresPython = "requires_python"
            }
        }

        /// One file of a release.
        struct File: Decodable, Sendable {
            let yanked: Bool?
            let requiresPython: String?

            enum CodingKeys: String, CodingKey {
                case yanked
                case requiresPython = "requires_python"
            }
        }

        let info: Info
        /// Every release's files, by version. PyPI calls it deprecated; without it only `info.version` is known.
        let releases: [String: [File]]?

        /// The newest release above `installed` with a file that isn't yanked and whose Python requirement `python`
        /// meets (nil: not known, so not checked), and that meets `requirement` (the tool's own, nil: none).
        /// Pre-releases only for a pre-release install, and never with `stableOnly` (a tool whose upgrade never takes
        /// one: pipx's).
        func newerVersion(than installed: String, python: String?, meeting requirement: Specifier? = nil,
                          stableOnly: Bool = false) -> String? {
            var candidates: [String] = []
            if let releases, !releases.isEmpty {
                candidates = releases.filter { _, files in
                    files.contains { $0.yanked != true && PyPI.pythonAllows($0.requiresPython, python: python) }
                }.map(\.key)
            } else if let version = info.version, info.yanked != true,
                      PyPI.pythonAllows(info.requiresPython, python: python) {
                candidates = [version]
            }
            if let requirement { candidates = candidates.filter(requirement.allows) }
            if stableOnly { candidates.removeAll { EcosystemVersion.isPrerelease($0, scheme: .pep440) } }
            return EcosystemVersion.newerVersion(than: installed, among: candidates, scheme: .pep440)
        }

        /// The project's Homepage link, else its home page, else its page on PyPI.
        var homepage: URL? {
            let listed = info.projectURLs?.first {
                $0.key.lowercased().filter(\.isLetter) == "homepage"
            }?.value
            return webURL(listed) ?? webURL(info.homePage) ?? webURL(info.projectURL)
        }
    }

    // MARK: lookups

    /// `name`'s project on PyPI, checked as one of `engine`'s names first; nil when PyPI has none (404). PyPI's other
    /// refusals, being offline and an answer that can't be read are `EngineError`s for `engine`; anything else (a
    /// cancelled task, demo mode's uncaptured answer) is thrown as it is.
    static func project(_ name: String, for engine: EngineID, from registry: any RegistryFetching) async throws
        -> Project? {
        let normalized = PackageNameRules.normalizedPythonName(name)
        try PackageNameRules.validate(normalized, for: engine)
        guard let url = URL(string: "https://pypi.org/pypi/\(normalized)/json") else {
            throw EngineError(engine: engine, message: "Invalid package name: \(name)")
        }
        let data: Data
        do {
            data = try await registry.get(url)
        } catch RegistryFetchError.status(404) {
            return nil
        } catch let error as RegistryFetchError {
            throw EngineError(engine: engine, message: "PyPI didn't answer for \(normalized): \(error)")
        } catch let error as URLError where error.code != .cancelled {
            throw EngineError(engine: engine, message: "Couldn't reach PyPI: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Project.self, from: data)
        } catch {
            throw EngineError(engine: engine, message: "Couldn't read PyPI's answer for \(normalized)")
        }
    }

    /// Each of `names` looked up on PyPI, `concurrentLookups` at a time, each name once, keyed by the name. Every
    /// lookup's failure (no such project, too large, offline) is that name's answer, so one can't cancel the others.
    static func projects(_ names: [String], for engine: EngineID, from registry: any RegistryFetching) async throws
        -> [String: Result<Project, any Error>] {
        let answers = try await concurrentMap(names, limit: concurrentLookups) { name in
            do {
                guard let project = try await Self.project(name, for: engine, from: registry) else {
                    return Result<Project, any Error>.failure(
                        EngineError(engine: engine, message: "PyPI has no project named \(name)"))
                }
                return .success(project)
            } catch {
                return .failure(error)
            }
        }
        try Task.checkCancellation()
        return answers
    }

    /// An outdated check where there was something to look up and no lookup answered, in the first failure's words
    /// (`OutdatedLookups.describe`, without URL credentials).
    static func noAnswer(_ failure: any Error, for engine: EngineID) -> EngineError {
        EngineError(engine: engine,
                    message: "BrewxPort couldn't check PyPI for newer versions: " + OutdatedLookups.describe(failure))
    }

    // MARK: search and details

    /// PyPI has no search, so the query is looked up as an exact project name. Text that can't be one finds nothing,
    /// without asking. The row is `engine`'s tool, keyed by the PEP 503 name, with PyPI's name, newest version and
    /// summary.
    static func search(_ query: String, for engine: EngineID, from registry: any RegistryFetching) async throws
        -> [Package] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EngineError(engine: engine, message: "Search query is empty") }
        guard PackageNameRules.isValid(text, for: engine),
              let project = try await project(text, for: engine, from: registry) else { return [] }
        let name = nonBlank(project.info.name) ?? text
        return [Package(id: PackageRef(engine: engine, kind: .tool, name: PackageNameRules.normalizedPythonName(name)),
                        displayName: name, latestVersion: nonBlank(project.info.version),
                        summary: nonBlank(project.info.summary))]
    }

    /// `ref`'s details from its project (`name`) on PyPI: the summary, home page and newest release. The name is
    /// checked before anything is asked.
    static func details(_ ref: PackageRef, project name: String, from registry: any RegistryFetching) async throws
        -> PackageDetails {
        try PackageNameRules.validate(name, for: ref.engine)
        guard let project = try await project(name, for: ref.engine, from: registry) else {
            throw EngineError(engine: ref.engine, message: "PyPI has no project named \(name)")
        }
        guard let version = nonBlank(project.info.version) else {
            throw EngineError(engine: ref.engine, message: "PyPI had no information for \(name)")
        }
        return PackageDetails(ref: ref, summary: nonBlank(project.info.summary), homepage: project.homepage,
                              latestVersion: version, reportedName: nonBlank(project.info.name))
    }

    // MARK: Python versions and requirements

    /// The release number of a Python as a tool names it: "Python 3.15.2" is 3.15.2, and "Python 3.15.0rc1" is
    /// 3.15.0, as pip checks a requirement against major.minor.micro. Nil when there's none.
    static func pythonVersion(_ text: String?) -> String? {
        guard let text else { return nil }
        var rest = Substring(text)
        if rest.lowercased().hasPrefix("python") { rest = rest.dropFirst("python".count) }
        let release = releaseNumber(rest.trimmingCharacters(in: .whitespaces))
        return release.isEmpty ? nil : release.joined(separator: ".")
    }

    /// The leading `N(.N)*` of a version, as its parts.
    static func releaseNumber(_ version: String) -> [Substring] {
        var parts: [Substring] = []
        for part in version.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { break }
            parts.append(digits)
            if digits.count != part.count { break }
        }
        return parts
    }

    /// Whether a Python at `python` meets a `requires_python` specifier. True when either isn't known, and when the
    /// specifier isn't one BrewxPort can read (`Specifier`): pip ignores an invalid requirement too, so a tool isn't
    /// held back for it.
    static func pythonAllows(_ specifier: String?, python: String?) -> Bool {
        guard let python, let text = nonBlank(specifier), let specifier = Specifier(text) else { return true }
        return specifier.allows(python)
    }

    /// A PEP 440 version specifier set, as far as BrewxPort reads them: clauses joined by commas, each `===`, `~=`,
    /// `==` or `!=` (with `.*`), `<=`, `>=`, `<` or `>` and a version (`>=3.8`, `>=3.8, <4`, `!=3.0.*`, `~=3.10`).
    struct Specifier: Equatable, Sendable {
        struct Clause: Equatable, Sendable {
            let op: String
            let version: String
        }

        let clauses: [Clause]

        private static let operators = ["===", "~=", "==", "!=", "<=", ">=", "<", ">"]

        /// Nil when any clause isn't one BrewxPort can read. Blank text has no clauses and allows every version.
        init?(_ text: String) {
            var clauses: [Clause] = []
            for part in text.split(separator: ",") {
                let clause = part.trimmingCharacters(in: .whitespaces)
                guard !clause.isEmpty else { continue }
                guard let op = Self.operators.first(where: { clause.hasPrefix($0) }) else { return nil }
                let version = clause.dropFirst(op.count).trimmingCharacters(in: .whitespaces)
                guard Self.isReadable(op, version) else { return nil }
                clauses.append(Clause(op: op, version: version))
            }
            self.clauses = clauses
        }

        /// Whether `version` meets every clause.
        func allows(_ version: String) -> Bool {
            clauses.allSatisfy { Self.matches(version, $0.op, $0.version) }
        }

        /// One exact version (`==0.6.0`, `===0.6.0`), which an upgrade never moves from.
        var isExact: Bool {
            guard clauses.count == 1, let only = clauses.first else { return false }
            return only.op == "===" || (only.op == "==" && !only.version.hasSuffix(".*"))
        }

        private static func isReadable(_ op: String, _ version: String) -> Bool {
            if op == "===" { return !version.isEmpty }
            if version.hasSuffix(".*") {
                let prefix = String(version.dropLast(2))
                return (op == "==" || op == "!=") && !prefix.isEmpty
                    && prefix.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
                    && releaseNumber(prefix).joined(separator: ".") == prefix
            }
            guard EcosystemVersion.isValid(version, scheme: .pep440) else { return false }
            return op != "~=" || releaseNumber(version).count >= 2
        }

        private static func matches(_ candidate: String, _ op: String, _ version: String) -> Bool {
            if op == "===" { return candidate == version }
            if version.hasSuffix(".*") {
                let inSeries = isInSeries(candidate, String(version.dropLast(2)))
                return op == "==" ? inSeries : !inSeries
            }
            let order = EcosystemVersion.compare(candidate, version, scheme: .pep440)
            switch op {
            case "==": return order == .orderedSame
            case "!=": return order != .orderedSame
            case "<": return order == .orderedAscending
            case "<=": return order != .orderedDescending
            case ">": return order == .orderedDescending
            case ">=": return order != .orderedAscending
            case "~=":
                // ~=3.10 is >=3.10 and ==3.*.
                let series = releaseNumber(version).dropLast().joined(separator: ".")
                return order != .orderedAscending && isInSeries(candidate, series)
            default: return false
            }
        }

        /// PEP 440's prefix match: `candidate`'s release number, padded with zeros, starts with `prefix`'s.
        private static func isInSeries(_ candidate: String, _ prefix: String) -> Bool {
            let wanted = releaseNumber(prefix)
            var have = releaseNumber(candidate)
            while have.count < wanted.count { have.append("0") }
            return zip(have, wanted).allSatisfy { a, b in
                a.drop { $0 == "0" } == b.drop { $0 == "0" }
            }
        }
    }
}
