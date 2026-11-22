import Foundation

/// A `.brewxportbundle` file: package identity, version and install options, nothing about the Mac or its owner.
///
/// Schema 1 is UTF-8 JSON with sorted keys, pretty-printed, slashes unescaped, nil optionals omitted:
/// `{ "arch", "createdBy", "entries": [ { "displayName", "engine", "id"?, "installedVersion"?, "kind", "name",
/// "options": { "extraArgs", "variants" }, "versionPin"? } ], "schemaVersion" }`.
///
/// A bundle file is untrusted. `decode` runs every entry through `BundleRules.check` and keeps only what the
/// verdict accepted; an entry that doesn't decode, fails the rules, or repeats an earlier ref is kept in
/// `unhandled` with its reason, and the rest still decode.
public struct BundleFile: Equatable, Sendable {
    public static let currentSchema = 1
    /// Largest file `decode` reads, in bytes. Checked before parsing.
    public static let maxFileBytes = 8 * 1024 * 1024
    /// Most entries a file may list. A file with more is refused as a whole (`.tooLarge`), not cut short.
    public static let maxEntries = 10_000
    /// Longest `UnhandledEntry.json` preview, in scalars of the original text, before "…".
    public static let maxJSONPreview = 2_000
    /// Longest `installedVersion`, `versionPin` or `id` kept from a file, in scalars, before "…".
    public static let maxInfoLength = 200

    public var schemaVersion: Int
    /// `"BrewxPort <version>"`, see `createdBy(_:)`.
    public var createdBy: String
    /// The architecture of the Mac that wrote the file. Information only.
    public var arch: Arch
    public var entries: [BundleEntry]
    /// Entries `decode` didn't take, in file order. Never written.
    public var unhandled: [UnhandledEntry]

    public init(
        schemaVersion: Int = BundleFile.currentSchema,
        createdBy: String,
        arch: Arch,
        entries: [BundleEntry],
        unhandled: [UnhandledEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.createdBy = createdBy
        self.arch = arch
        self.entries = entries
        self.unhandled = unhandled
    }

    /// `CFBundleShortVersionString` from an Info dictionary (the app passes `Bundle.main.infoDictionary`), else `"0.0.0"`.
    public static func appVersion(_ info: [String: Any]?) -> String {
        (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// `"BrewxPort " + appVersion(info)`.
    public static func createdBy(_ info: [String: Any]?) -> String {
        "BrewxPort " + appVersion(info)
    }

    // MARK: decoding

    /// Reads a bundle file. Throws only for the file as a whole: not JSON, not a bundle (no integer
    /// `schemaVersion`, string `createdBy`, known `arch` and `entries` array), a schema this version can't read, or
    /// a file over `maxFileBytes` or `maxEntries`.
    public static func decode(_ data: Data) throws -> BundleFile {
        guard data.count <= maxFileBytes else { throw BundleFileError.tooLarge }
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw BundleFileError.notJSON
        }
        guard let object = top as? [String: Any], let schema = integer(object["schemaVersion"]) else {
            throw BundleFileError.notABundle
        }
        guard schema >= 1 else { throw BundleFileError.unsupportedSchema(schema) }
        guard schema <= currentSchema else { throw BundleFileError.newerSchema(schema) }
        guard let createdBy = object["createdBy"] as? String,
              let archName = object["arch"] as? String, let arch = Arch(rawValue: archName),
              let rawEntries = object["entries"] as? [Any]
        else { throw BundleFileError.notABundle }
        guard rawEntries.count <= maxEntries else { throw BundleFileError.tooLarge }

        var entries: [BundleEntry] = []
        var unhandled: [UnhandledEntry] = []
        var firstIndex: [PackageRef: Int] = [:]
        for (index, raw) in rawEntries.enumerated() {
            switch accept(raw) {
            case .failure(let reason):
                unhandled.append(UnhandledEntry(index: index, reason: reason.text, json: jsonText(raw)))
            case .success(let entry):
                // Exact, case-sensitive ref match: `Borders` and `borders` both decode here. Case-insensitive
                // matching against what's installed is the preview's job (`BundleRules.matchKey`).
                if let first = firstIndex[entry.ref] {
                    unhandled.append(UnhandledEntry(index: index, reason: "listed twice; entry \(first + 1) is used",
                                                    json: jsonText(raw)))
                } else {
                    firstIndex[entry.ref] = index
                    entries.append(entry)
                }
            }
        }
        return BundleFile(schemaVersion: schema, createdBy: createdBy, arch: arch, entries: entries, unhandled: unhandled)
    }

    private struct Reason: Error { let text: String }

    /// One raw entry to an accepted `BundleEntry`, or the reason it isn't one. Reasons are written here, never taken
    /// from a `DecodingError` (which quotes raw values); untrusted values go through `BundleRules.shown`.
    private static func accept(_ raw: Any) -> Result<BundleEntry, Reason> {
        guard let object = raw as? [String: Any] else { return .failure(Reason(text: "isn't a JSON object")) }
        guard let engineName = object["engine"] as? String else { return .failure(Reason(text: "has no engine")) }
        guard EngineID(rawValue: engineName) != nil else {
            return .failure(Reason(text: "names an engine BrewxPort doesn't know: “\(BundleRules.shown(engineName))”"))
        }
        guard let kindName = object["kind"] as? String else { return .failure(Reason(text: "has no kind")) }
        guard PackageKind(rawValue: kindName) != nil else {
            return .failure(Reason(text: "names a package kind BrewxPort doesn't know: “\(BundleRules.shown(kindName))”"))
        }
        guard object["name"] is String else { return .failure(Reason(text: "has no name")) }

        let decoded: BundleEntry
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            decoded = try JSONDecoder().decode(BundleEntry.self, from: data)
        } catch {
            return .failure(Reason(text: "has a field of the wrong type"))
        }

        let verdict = BundleRules.check(
            engine: decoded.engine, kind: decoded.kind, name: decoded.name,
            displayName: object["displayName"] as? String,
            variants: decoded.options.variants, extraArgs: decoded.options.extraArgs
        )
        switch verdict {
        case .rejected(let reason):
            return .failure(Reason(text: reason))
        case .accepted(let ref, let displayName, let options):
            // Display text from the file is sanitized here: control and format scalars escaped, length capped.
            return .success(BundleEntry(
                engine: ref.engine, kind: ref.kind, name: ref.name, displayName: displayName,
                installedVersion: decoded.installedVersion.map(info), versionPin: decoded.versionPin.map(info),
                options: options, id: decoded.id.map(info)
            ))
        }
    }

    /// An integer JSON number. `true`/`false` (which bridge to 1/0) and fractions are not.
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    private static func info(_ text: String) -> String {
        BundleRules.escaped(text, limit: maxInfoLength)
    }

    /// The raw entry as JSON for the preview: control and format scalars escaped, cut to `maxJSONPreview` scalars.
    private static func jsonText(_ raw: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: options) else { return "" }
        return BundleRules.escaped(String(decoding: data, as: UTF8.self), limit: maxJSONPreview)
    }

    // MARK: encoding

    private struct Wire: Encodable {
        let schemaVersion: Int
        let createdBy: String
        let arch: Arch
        let entries: [BundleEntry]
    }

    /// The file's bytes. `unhandled` is never written, and neither is any `options.version`.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(Wire(schemaVersion: schemaVersion, createdBy: createdBy, arch: arch, entries: entries))
    }
}

/// One package in a bundle.
public struct BundleEntry: Hashable, Sendable {
    public var engine: EngineID
    public var kind: PackageKind
    public var name: String
    /// After `decode`, the rules' display name: the name itself, or for mas the cleaned app name.
    public var displayName: String
    /// The version on the Mac that wrote the file. Information for the preview. After `decode`, this, `versionPin`
    /// and `id` are display-safe: control and format scalars escaped, at most `BundleFile.maxInfoLength` scalars.
    public var installedVersion: String?
    /// Kept and shown, never applied: no engine pins yet. The exporter writes none.
    public var versionPin: String?
    /// Only `variants` and `extraArgs` are read or written; `version` is never taken from or put in a file.
    public var options: InstallOptions
    /// Reserved for cross-engine mapping: kept and written as held (the exporter sets nil), otherwise unused.
    public var id: String?

    public var ref: PackageRef { PackageRef(engine: engine, kind: kind, name: name) }

    public init(
        engine: EngineID,
        kind: PackageKind,
        name: String,
        displayName: String,
        installedVersion: String? = nil,
        versionPin: String? = nil,
        options: InstallOptions = InstallOptions(),
        id: String? = nil
    ) {
        self.engine = engine
        self.kind = kind
        self.name = name
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.versionPin = versionPin
        self.options = options
        self.id = id
    }
}

extension BundleEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case engine, kind, name, displayName, installedVersion, versionPin, options, id
    }

    /// The only option keys in a file. Not `InstallOptions`' own coding, which would read `version`.
    private enum OptionKeys: String, CodingKey {
        case variants, extraArgs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(EngineID.self, forKey: .engine)
        kind = try c.decode(PackageKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? name
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        versionPin = try c.decodeIfPresent(String.self, forKey: .versionPin)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        if c.contains(.options) {
            let o = try c.nestedContainer(keyedBy: OptionKeys.self, forKey: .options)
            options = InstallOptions(
                version: nil,
                variants: try o.decodeIfPresent([String].self, forKey: .variants) ?? [],
                extraArgs: try o.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
            )
        } else {
            options = InstallOptions()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engine, forKey: .engine)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(installedVersion, forKey: .installedVersion)
        try c.encodeIfPresent(versionPin, forKey: .versionPin)
        try c.encodeIfPresent(id, forKey: .id)
        var o = c.nestedContainer(keyedBy: OptionKeys.self, forKey: .options)
        try o.encode(options.variants, forKey: .variants)
        try o.encode(options.extraArgs, forKey: .extraArgs)
    }
}

/// An entry `BundleFile.decode` didn't take.
public struct UnhandledEntry: Hashable, Sendable {
    /// The entry's 0-based position in the file's `entries` array. Reasons shown to people count from 1
    /// ("listed twice; entry 1 is used" names `index` 0), so show `index + 1` next to them.
    public var index: Int
    /// Why, shown as is; never holds a raw control character.
    public var reason: String
    /// The entry as JSON text (sorted keys), for the preview: control and format scalars escaped as `\u{…}`, at most
    /// `BundleFile.maxJSONPreview` scalars of the original plus "…".
    public var json: String

    public init(index: Int, reason: String, json: String) {
        self.index = index
        self.reason = reason
        self.json = json
    }
}

public enum BundleFileError: Error, Equatable {
    case notJSON
    case notABundle
    case newerSchema(Int)
    case unsupportedSchema(Int)
    /// Over `BundleFile.maxFileBytes` or `BundleFile.maxEntries`.
    case tooLarge
}
