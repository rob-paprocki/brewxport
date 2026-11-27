import Foundation

/// Why an engine holds an update back, and what from: every automatic update, or every update at all.
public struct UpdateHold: Hashable, Sendable {
    /// One short line for the row ("Needs Rust 1.85").
    public let reason: String
    /// Never part of an automatic update (background updates leave it out).
    public let blocksAutomatic: Bool
    /// Never part of any update: the person can't pick it either.
    public let blocksManual: Bool

    public init(reason: String, blocksAutomatic: Bool, blocksManual: Bool) {
        self.reason = reason
        self.blocksAutomatic = blocksAutomatic
        self.blocksManual = blocksManual
    }
}

/// An update an engine found and holds back (`OutdatedReport.held`), with why.
public struct HeldUpdate: Hashable, Sendable {
    /// The row: the package with its installed and newer version.
    public let package: Package
    public let hold: UpdateHold

    public init(package: Package, hold: UpdateHold) {
        self.package = package
        self.hold = hold
    }
}

/// R6: the packages one outdated check couldn't look up while the rest of it answered (a registry error for that
/// package alone). They're in neither the updates nor the holds.
public struct UncheckedPackages: Hashable, Sendable {
    /// Package name → one line saying why.
    public let reasons: [String: String]
    /// The engine said lookups failed without naming every one (pipx's error without a venv, Bun's exit 1): some
    /// package besides the ones in `reasons` couldn't be checked.
    public let unnamed: Bool
    /// One line about the check as a whole, in the engine's words, when it answered but couldn't do all it should
    /// (R26: npm without its list of globals can't tell folder and linked installs apart).
    public let note: String?

    public init(reasons: [String: String] = [:], unnamed: Bool = false, note: String? = nil) {
        self.reasons = reasons
        self.unnamed = unnamed
        self.note = note
    }

    public static let none = UncheckedPackages()

    /// The named ones, sorted.
    public var names: [String] { reasons.keys.sorted() }
    /// How many are named.
    public var count: Int { reasons.count }
    public var isEmpty: Bool { reasons.isEmpty && !unnamed && note == nil }
}

/// One engine's outdated check (`Engine.checkOutdated()`): its updates, what it couldn't check, and what it holds back.
public struct OutdatedReport: Sendable, Equatable {
    /// The updates `listOutdated()` gives. A held update the person may still pick (`blocksManual` false: a gem that
    /// came with Ruby) is here as well as in `held`; one nobody may pick isn't.
    public var packages: [Package]
    public var unchecked: UncheckedPackages
    public var held: [HeldUpdate]

    public init(packages: [Package], unchecked: UncheckedPackages = .none, held: [HeldUpdate] = []) {
        self.packages = packages
        self.unchecked = unchecked
        self.held = held
    }

    /// How many packages the check named as not checked.
    public var uncheckedCount: Int { unchecked.count }
}

/// R6: an outdated check that looks each package up on its own (PyPI, crates.io, RubyGems.org, GitHub). A failed
/// lookup is that package's alone: it's left out, named in what `tally` returns, and the check goes on.
enum OutdatedLookups {
    /// Goes through `items` with their lookups' answers (`answers`, by `key`), handing each answer to `found`; an item
    /// without a lookup is skipped. Returns the items whose lookup failed, by `name`, each with `describe` of its
    /// error. When no lookup answered, throws what `noAnswer` gives for the first failure (nil when none failed),
    /// unless that's nil.
    static func tally<Item, Answer>(
        _ items: [Item], answers: [String: Result<Answer, any Error>], key: (Item) -> String,
        name: (Item) -> String, noAnswer: ((any Error)?) -> (any Error)?, found: (Item, Answer) throws -> Void
    ) throws -> UncheckedPackages {
        var answered = false
        var firstFailure: (any Error)?
        var failed: [String: String] = [:]
        for item in items {
            switch answers[key(item)] {
            case .success(let answer)?:
                answered = true
                try found(item, answer)
            case .failure(let error)?:
                firstFailure = firstFailure ?? error
                failed[name(item)] = describe(error)
            case nil:
                continue
            }
        }
        if !answered, let error = noAnswer(firstFailure) { throw error }
        return UncheckedPackages(reasons: failed)
    }

    /// One line for a failed lookup: an engine's own message, a registry's refusal, else the system's words, without
    /// any URL credentials. The one wording for every engine's lookups (PyPI, crates.io, RubyGems.org, GitHub), in a
    /// package's reason and in a whole check's failure.
    static func describe(_ error: any Error) -> String {
        let text: String
        if let error = error as? EngineError {
            text = error.message
        } else if let error = error as? RegistryFetchError {
            text = String(describing: error)
        } else {
            text = error.localizedDescription
        }
        return CredentialScrubber.scrub(text)
    }
}
