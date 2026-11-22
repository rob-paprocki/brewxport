import Foundation

public struct ReleaseAsset: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var sha256: String
    public var size: Int

    public init(name: String, url: URL, sha256: String, size: Int) {
        self.name = name
        self.url = url
        self.sha256 = sha256
        self.size = size
    }
}

/// The part of a GitHub "latest release" response the setup flow needs.
public struct GitHubRelease: Sendable {
    public var tag: String
    public var assets: [ReleaseAsset]

    public init(tag: String, assets: [ReleaseAsset]) {
        self.tag = tag
        self.assets = assets
    }

    /// Downloads may only come from GitHub itself, over HTTPS.
    static let allowedHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    private struct Wire: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
            var digest: String?
            var size: Int
        }
        var tag_name: String
        var assets: [Asset]
    }

    /// Assets without a `sha256:` digest are dropped, and so are assets whose download URL isn't HTTPS on an allowed
    /// host. One odd asset doesn't spoil the release; choosing an asset still fails (`noAsset`) when the one needed
    /// was dropped.
    public static func decode(_ data: Data) throws -> GitHubRelease {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var assets: [ReleaseAsset] = []
        for item in wire.assets {
            guard let url = URL(string: item.browser_download_url),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  allowedHosts.contains(host)
            else { continue }
            let prefix = "sha256:"
            guard let digest = item.digest, digest.hasPrefix(prefix) else { continue }
            let hex = String(digest.dropFirst(prefix.count)).lowercased()
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { continue }
            assets.append(ReleaseAsset(name: item.name, url: url, sha256: hex, size: item.size))
        }
        return GitHubRelease(tag: wire.tag_name, assets: assets)
    }

    /// The installer for `target` on `host`.
    public static func asset(for target: SetupTarget, in release: GitHubRelease, host: HostInfo) throws -> ReleaseAsset {
        func find(_ matches: (String) -> Bool, missing: String) throws -> ReleaseAsset {
            guard let found = release.assets.first(where: { matches($0.name) }) else {
                throw SetupError.noAsset(missing)
            }
            return found
        }
        switch target {
        case .homebrew:
            guard host.appleSilicon else {
                throw SetupError.unsupportedHost("Homebrew's installer needs an Apple silicon Mac.")
            }
            return try find({ $0 == "Homebrew.pkg" }, missing: "The Homebrew release has no installer package")
        case .macports:
            let major = host.macOSMajor
            return try find({ name in
                // MacPorts-<version>-<macOS major>-<Codename>.pkg; the .pkg.asc signatures don't match.
                let parts = name.split(separator: "-", omittingEmptySubsequences: false)
                return parts.count == 4 && parts[0] == "MacPorts" && parts[2] == Substring("\(major)")
                    && parts[3].hasSuffix(".pkg")
            }, missing: "MacPorts has no installer for macOS \(major) yet")
        case .nanobrew:
            let name = host.appleSilicon ? "nb-arm64-apple-darwin.tar.gz" : "nb-x86_64-apple-darwin.tar.gz"
            return try find({ $0 == name }, missing: "The nanobrew release has no download for this Mac")
        case .commandLineTools:
            throw SetupError.noAsset("The Command Line Tools come from Apple, not GitHub")
        }
    }
}
