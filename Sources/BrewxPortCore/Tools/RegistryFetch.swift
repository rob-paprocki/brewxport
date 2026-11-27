import Foundation

/// Reads one package registry URL (the latest version of a crate, a PyPI project's JSON, a gem's index line).
/// Language engines get one injected, so their tests use a fake and never reach the network.
public protocol RegistryFetching: Sendable {
    /// The body of a 200 answer from `url`. Throws `RegistryFetchError` for a URL or redirect BrewxPort may not
    /// follow and for any other status, or the URL loading error (offline, timed out).
    func get(_ url: URL) async throws -> Data
}

public enum RegistryFetchError: Error, Equatable, Sendable {
    /// The URL isn't HTTPS to one of the allowed registry hosts, or it carries credentials or another port.
    case notAllowed
    /// The registry redirected to another host, or away from HTTPS.
    case redirectRefused
    /// The registry answered with this status instead of 200 (404: no such package).
    case status(Int)
    /// The answer was larger than this many bytes (`LiveRegistryFetch.maxResponseBytes`); reading stopped there.
    case tooLarge(Int)
}

extension RegistryFetchError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notAllowed:
            return "BrewxPort contacts only npm, PyPI, crates.io, RubyGems and GitHub over HTTPS, and this address "
                + "isn't one of them."
        case .redirectRefused:
            return "The registry sent BrewxPort to another site, so nothing was read."
        case .status(let code):
            return "The registry answered with HTTP status \(code)."
        case .tooLarge(let limit):
            return "The registry's answer was larger than \(Int64(limit).formatted(.byteCount(style: .memory))), "
                + "so BrewxPort stopped reading it."
        }
    }
}

/// The app's registry reader: HTTPS GETs to the allowlisted hosts only, with a BrewxPort User-Agent, a 10-second
/// limit per request (redirects included), an ephemeral session (no cache, cookies or stored credentials), and
/// redirects followed only within the host first asked. Callers put only package names in the URLs.
public struct LiveRegistryFetch: RegistryFetching {
    /// Where language engines may look up versions: npm, PyPI, crates.io's index and API, RubyGems' API and compact
    /// index, and GitHub. Exactly these.
    public static let allowedHosts: Set<String> = [
        "registry.npmjs.org", "pypi.org", "index.crates.io", "crates.io", "github.com", "rubygems.org",
        "index.rubygems.org",
    ]

    /// `BrewxPort/<version> (+https://github.com/rob-paprocki/brewxport)`: crates.io refuses requests without a
    /// User-Agent naming the app, and PyPI asks clients to send one.
    public static func userAgent(appVersion: String) -> String {
        "BrewxPort/\(appVersion) (+https://github.com/rob-paprocki/brewxport)"
    }

    /// HTTPS to an allowed host on the default port, without a user name or password.
    public static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              allowedHosts.contains(host), url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }

    /// A redirect (or the final response) may only stay on the host the request went to, over HTTPS.
    static func allowsRedirect(from original: URL, to target: URL?) -> Bool {
        guard allows(target), let target else { return false }
        return target.host?.lowercased() == original.host?.lowercased()
    }

    /// The session settings: ephemeral, nothing cached or stored, 10 seconds per request and in total.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        let limit = BrewxPortTimeouts.seconds(BrewxPortTimeouts.registryQuery)
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// The largest answer read (8 MiB). PyPI's JSON for a project with thousands of releases is a few MB; anything
    /// bigger isn't a registry answer BrewxPort needs, and reading stops there.
    public static let maxResponseBytes = 8 * 1024 * 1024

    /// The one session every fetcher uses (`configuration()`), so engines share its connections.
    static let sharedSession = URLSession(configuration: configuration())

    let session: URLSession
    private let userAgent: String
    private let maxBytes: Int

    /// appVersion: the app's `CFBundleShortVersionString` (`BundleFile.appVersion`), for the User-Agent.
    public init(appVersion: String) {
        self.init(appVersion: appVersion, session: Self.sharedSession)
    }

    /// Tests pass a session whose transport is a stub, and a smaller limit.
    init(appVersion: String, session: URLSession, maxBytes: Int = maxResponseBytes) {
        self.session = session
        userAgent = Self.userAgent(appVersion: appVersion)
        self.maxBytes = maxBytes
    }

    public func get(_ url: URL) async throws -> Data {
        guard Self.allows(url) else { throw RegistryFetchError.notAllowed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: BrewxPortTimeouts.seconds(BrewxPortTimeouts.registryQuery))
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        let transfer = RegistryTransfer(original: url, maxBytes: maxBytes)
        task.delegate = transfer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(task, continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One registry request's delegate: follows a redirect only within the host first asked, over HTTPS; accepts only a
/// 200 from that host; collects the body as it arrives in chunks, stopping once it passes the size limit. Whatever
/// stops it cancels the task, and the task's end hands over the body or the first reason it stopped.
final class RegistryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let original: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var body = Data()
    private var failure: RegistryFetchError?
    private var continuation: CheckedContinuation<Data, Error>?

    init(original: URL, maxBytes: Int) {
        self.original = original
        self.maxBytes = maxBytes
    }

    /// Keeps the continuation, then starts the task (so its end always finds the continuation).
    func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Data, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    /// Records the first reason to stop and cancels the task; `didCompleteWithError` then reports it.
    private func stop(_ task: URLSessionTask, _ reason: RegistryFetchError) {
        lock.withLock { if failure == nil { failure = reason } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if LiveRegistryFetch.allowsRedirect(from: original, to: request.url) {
            completionHandler(request)
        } else {
            stop(task, .redirectRefused)
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !LiveRegistryFetch.allowsRedirect(from: original, to: response.url) {
            stop(dataTask, .redirectRefused)
        } else if status != 200 {
            stop(dataTask, .status(status))
        } else if response.expectedContentLength > Int64(maxBytes) {
            // A declared length over the limit is refused before any of the body is read.
            stop(dataTask, .tooLarge(maxBytes))
        } else {
            lock.withLock { body.reserveCapacity(Int(max(0, response.expectedContentLength))) }
            completionHandler(.allow)
            return
        }
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard failure == nil else { return false }
            guard body.count + data.count <= maxBytes else { return true }
            body.append(data)
            return false
        }
        if tooLarge { stop(dataTask, .tooLarge(maxBytes)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, result) = lock.withLock { () -> (CheckedContinuation<Data, Error>?, Result<Data, Error>) in
            let waiting = continuation
            continuation = nil
            if let failure { return (waiting, .failure(failure)) }
            if let error { return (waiting, .failure(error)) }
            return (waiting, .success(body))
        }
        waiting?.resume(with: result)
    }
}
