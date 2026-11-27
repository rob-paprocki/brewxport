import Foundation
@testable import BrewxPortCore

/// Test double for `RegistryFetching`: canned answers by URL, with the live fetcher's host rules and size limit, so an
/// engine test that asks for a host BrewxPort may not contact (or gets an oversized answer) fails the same way the app
/// would. A URL with no answer is a 404.
final class FakeRegistryFetch: RegistryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: Result<Data, Error>]
    private let maxBytes: Int
    private var _requested: [URL] = []

    init(_ answers: [String: Result<Data, Error>] = [:], maxBytes: Int = LiveRegistryFetch.maxResponseBytes) {
        self.answers = answers
        self.maxBytes = maxBytes
    }

    /// Answers as text bodies, keyed by absolute URL string.
    convenience init(bodies: [String: String], maxBytes: Int = LiveRegistryFetch.maxResponseBytes) {
        self.init(bodies.mapValues { .success(Data($0.utf8)) }, maxBytes: maxBytes)
    }

    /// The URLs that passed the host rules, in the order they were asked for.
    var requested: [URL] { lock.withLock { _requested } }

    func get(_ url: URL) async throws -> Data {
        guard LiveRegistryFetch.allows(url) else { throw RegistryFetchError.notAllowed }
        lock.withLock { _requested.append(url) }
        guard let answer = answers[url.absoluteString] else { throw RegistryFetchError.status(404) }
        let data = try answer.get()
        guard data.count <= maxBytes else { throw RegistryFetchError.tooLarge(maxBytes) }
        return data
    }
}
