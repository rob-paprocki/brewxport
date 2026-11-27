import Foundation
import Testing
@testable import BrewxPortCore

/// No test here reaches the network: the live fetcher either refuses a URL before making a request, or runs on a
/// session whose only transport is `StubTransport` (canned answers, every request recorded).
@Suite struct RegistryFetchTests {
    static let hosts: Set<String> = ["registry.npmjs.org", "pypi.org", "index.crates.io", "crates.io", "github.com",
                                     "rubygems.org", "index.rubygems.org"]

    /// One session for every test, like the app's one shared session, but on the stub transport.
    static let stubSession: URLSession = {
        let configuration = LiveRegistryFetch.configuration()
        configuration.protocolClasses = [StubTransport.self]
        return URLSession(configuration: configuration)
    }()

    static func live(maxBytes: Int = LiveRegistryFetch.maxResponseBytes) -> LiveRegistryFetch {
        LiveRegistryFetch(appVersion: "9.9.9", session: stubSession, maxBytes: maxBytes)
    }

    @Test func allowlistIsExact() {
        #expect(LiveRegistryFetch.allowedHosts == Self.hosts)
    }

    @Test func everyFetcherSharesOneSession() {
        #expect(LiveRegistryFetch(appVersion: "1.0").session === LiveRegistryFetch(appVersion: "2.0").session)
        #expect(LiveRegistryFetch(appVersion: "1.0").session === LiveRegistryFetch.sharedSession)
        #expect(LiveRegistryFetch.sharedSession.configuration.timeoutIntervalForResource == 10)
        #expect(LiveRegistryFetch.sharedSession.configuration.urlCache == nil)
    }

    @Test func bodyArrivingInManyChunksIsReadWhole() async throws {
        // The stub hands the body over in 4 KiB pieces.
        let marker = UUID().uuidString
        let url = "https://pypi.org/pypi/\(marker)/json"
        let body = (0..<200_000).map { String($0 % 10) }.joined()
        StubTransport.answer(url, status: 200, body: body)
        let data = try await Self.live().get(URL(string: url)!)
        #expect(data == Data(body.utf8))
        // Over a limit that falls mid-chunk: refused, not truncated.
        await #expect(throws: RegistryFetchError.tooLarge(150_001)) {
            try await Self.live(maxBytes: 150_001).get(URL(string: url)!)
        }
        #expect(try await Self.live(maxBytes: 200_000).get(URL(string: url)!).count == 200_000)
    }

    @Test func userAgentNamesBrewxPortAndItsVersion() {
        #expect(LiveRegistryFetch.userAgent(appVersion: "0.8.0")
                == "BrewxPort/0.8.0 (+https://github.com/rob-paprocki/brewxport)")
    }

    @Test func sessionIsEphemeralWithTenSecondTimeouts() {
        #expect(BrewxPortTimeouts.registryQuery == .seconds(10))
        let configuration = LiveRegistryFetch.configuration()
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 10)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func fetchRefusesOtherHosts() async {
        for host in Self.hosts {
            #expect(LiveRegistryFetch.allows(URL(string: "https://\(host)/x")), "\(host)")
        }
        #expect(LiveRegistryFetch.allows(URL(string: "https://PyPI.org/pypi/black/json")))
        #expect(LiveRegistryFetch.allows(URL(string: "https://pypi.org:443/pypi/black/json")))
        let refused = [
            "http://pypi.org/pypi/black/json", "https://evil.example/x", "https://pypi.org.evil.example/x",
            "https://files.pythonhosted.org/x", "https://api.github.com/repos/x/y", "https://registry.yarnpkg.com/x",
            // Credentials in a URL (split so the repo check doesn't read them as email addresses).
            "https://someone:secret" + "@pypi.org/x", "https://token" + "@registry.npmjs.org/x",
            "https://pypi.org:8443/x",
            "ftp://github.com/x", "file:///etc/passwd", "pypi.org/x", "https:///x",
        ]
        for text in refused {
            #expect(!LiveRegistryFetch.allows(URL(string: text)), "\(text)")
        }
        #expect(!LiveRegistryFetch.allows(nil))

        // The live fetcher refuses before any request is made.
        let marker = UUID().uuidString
        let fetch = Self.live()
        let refusedHere = ["https://evil.example/\(marker)", "http://pypi.org/\(marker)",
                           "https://api.github.com/\(marker)"]
        for text in refusedHere {
            await #expect(throws: RegistryFetchError.notAllowed) { try await fetch.get(URL(string: text)!) }
        }
        #expect(StubTransport.requests(containing: marker).isEmpty)
    }

    @Test func fetchRefusesCrossHostRedirect() async throws {
        let pypi = URL(string: "https://pypi.org/pypi/Black/json")!
        // PyPI redirects a name to its normalized form on the same host: followed.
        #expect(LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "https://pypi.org/pypi/black/json")))
        #expect(LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "https://PYPI.org/pypi/black/json")))
        // Another host, even an allowlisted one, a downgrade to http, or credentials: refused.
        let npm = URL(string: "https://registry.npmjs.org/tool/latest")!
        #expect(!LiveRegistryFetch.allowsRedirect(from: npm, to: URL(string: "https://github.com/tool")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: URL(string: "https://index.crates.io/ri/pg/ripgrep")!,
                                                  to: URL(string: "https://crates.io/api/v1/crates/ripgrep")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "https://files.pythonhosted.org/x")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "http://pypi.org/pypi/black/json")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "https://evil.example/x")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: pypi, to: URL(string: "https://someone:x" + "@pypi.org/x")))
        #expect(!LiveRegistryFetch.allowsRedirect(from: pypi, to: nil))

        // Through the live fetcher: the redirect is refused and the other host never asked.
        let marker = UUID().uuidString
        let start = "https://registry.npmjs.org/\(marker)/latest"
        StubTransport.answer(start, status: 302, location: "https://github.com/\(marker)")
        StubTransport.answer("https://github.com/\(marker)", status: 200, body: "{}")
        await #expect(throws: RegistryFetchError.redirectRefused) { try await Self.live().get(URL(string: start)!) }
        #expect(StubTransport.requests(containing: marker).map { $0.url?.host } == ["registry.npmjs.org"])

        let downgrade = "https://pypi.org/pypi/\(marker)/json"
        StubTransport.answer(downgrade, status: 301, location: "http://pypi.org/pypi/\(marker)/json")
        await #expect(throws: RegistryFetchError.redirectRefused) { try await Self.live().get(URL(string: downgrade)!) }
        #expect(!StubTransport.requests(containing: marker).contains { $0.url?.scheme == "http" })
    }

    @Test func sameHostRedirectIsFollowed() async throws {
        let marker = UUID().uuidString
        let start = "https://pypi.org/pypi/\(marker)-Tool/json"
        let normalized = "https://pypi.org/pypi/\(marker)-tool/json"
        StubTransport.answer(start, status: 301, location: normalized)
        StubTransport.answer(normalized, status: 200, body: #"{"info":{"version":"1.0"}}"#)
        let data = try await Self.live().get(URL(string: start)!)
        #expect(String(decoding: data, as: UTF8.self) == #"{"info":{"version":"1.0"}}"#)
    }

    @Test func requestCarriesUserAgentAndTimeout() async throws {
        let marker = UUID().uuidString
        let url = "https://index.crates.io/\(marker)"
        StubTransport.answer(url, status: 200, body: "line\n")
        _ = try await Self.live().get(URL(string: url)!)
        let request = try #require(StubTransport.requests(containing: marker).first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")
                == "BrewxPort/9.9.9 (+https://github.com/rob-paprocki/brewxport)")
        #expect(request.timeoutInterval == 10)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func statusOtherThan200Throws() async {
        let marker = UUID().uuidString
        StubTransport.answer("https://pypi.org/pypi/\(marker)/json", status: 404, body: "{}")
        StubTransport.answer("https://index.crates.io/\(marker)", status: 503, body: "")
        await #expect(throws: RegistryFetchError.status(404)) {
            try await Self.live().get(URL(string: "https://pypi.org/pypi/\(marker)/json")!)
        }
        await #expect(throws: RegistryFetchError.status(503)) {
            try await Self.live().get(URL(string: "https://index.crates.io/\(marker)")!)
        }
    }

    @Test func fakeFollowsTheLiveHostRules() async throws {
        let fake = FakeRegistryFetch(bodies: ["https://pypi.org/pypi/black/json": "{}"])
        #expect(try await fake.get(URL(string: "https://pypi.org/pypi/black/json")!) == Data("{}".utf8))
        await #expect(throws: RegistryFetchError.status(404)) {
            try await fake.get(URL(string: "https://pypi.org/pypi/nope/json")!)
        }
        await #expect(throws: RegistryFetchError.notAllowed) {
            try await fake.get(URL(string: "https://evil.example/x")!)
        }
        #expect(fake.requested.map(\.absoluteString)
                == ["https://pypi.org/pypi/black/json", "https://pypi.org/pypi/nope/json"])
        let small = FakeRegistryFetch(bodies: ["https://pypi.org/pypi/big/json": "0123456789"], maxBytes: 9)
        await #expect(throws: RegistryFetchError.tooLarge(9)) {
            try await small.get(URL(string: "https://pypi.org/pypi/big/json")!)
        }
    }

    @Test func responseOverTheSizeLimitIsRefused() async throws {
        #expect(LiveRegistryFetch.maxResponseBytes == 8 * 1024 * 1024)
        let marker = UUID().uuidString
        let exact = "https://pypi.org/pypi/\(marker)-exact/json"
        let declared = "https://pypi.org/pypi/\(marker)-declared/json"
        let streamed = "https://pypi.org/pypi/\(marker)-streamed/json"
        StubTransport.answer(exact, status: 200, body: String(repeating: "x", count: 16), declaresLength: true)
        // One byte over: refused from the declared Content-Length before reading, or cut off while reading.
        StubTransport.answer(declared, status: 200, body: String(repeating: "x", count: 17), declaresLength: true)
        StubTransport.answer(streamed, status: 200, body: String(repeating: "x", count: 17))
        let fetch = Self.live(maxBytes: 16)
        #expect(try await fetch.get(URL(string: exact)!).count == 16)
        await #expect(throws: RegistryFetchError.tooLarge(16)) { try await fetch.get(URL(string: declared)!) }
        await #expect(throws: RegistryFetchError.tooLarge(16)) { try await fetch.get(URL(string: streamed)!) }
    }

    @Test func errorsReadPlainly() {
        #expect(String(describing: RegistryFetchError.status(503)) == "The registry answered with HTTP status 503.")
        #expect(String(describing: RegistryFetchError.redirectRefused)
                == "The registry sent BrewxPort to another site, so nothing was read.")
        #expect(String(describing: RegistryFetchError.tooLarge(LiveRegistryFetch.maxResponseBytes))
                .hasPrefix("The registry's answer was larger than 8"))
        #expect(String(describing: RegistryFetchError.notAllowed).contains("npm, PyPI, crates.io, RubyGems and GitHub"))
    }
}

/// A URL loading transport for tests: answers registered URLs (a redirect, or a status and body), fails anything
/// else, and records every request it's handed. Tests use unique URLs, so they can run side by side.
final class StubTransport: URLProtocol, @unchecked Sendable {
    private struct Answer {
        var status: Int
        var location: String?
        var body: Data
        var declaresLength: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    /// declaresLength: send a Content-Length header with the body's size.
    static func answer(_ url: String, status: Int, location: String? = nil, body: String = "",
                       declaresLength: Bool = false) {
        lock.withLock {
            answers[url] = Answer(status: status, location: location, body: Data(body.utf8),
                                  declaresLength: declaresLength)
        }
    }

    static func requests(containing marker: String) -> [URLRequest] {
        lock.withLock { seen.filter { $0.url?.absoluteString.contains(marker) == true } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen.append(request)
            return request.url.flatMap { Self.answers[$0.absoluteString] }
        }
        guard let url = request.url, let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = answer.location.map { ["Location": $0] } ?? [:]
        if answer.declaresLength { headers["Content-Length"] = String(answer.body.count) }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        if let location = answer.location, let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < answer.body.count {
            let end = min(offset + 4096, answer.body.count)
            client?.urlProtocol(self, didLoad: answer.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
