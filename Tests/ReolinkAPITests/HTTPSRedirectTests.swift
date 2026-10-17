import Testing
import Foundation
@testable import ReolinkAPI

/// A camera that redirects its HTTP web port to HTTPS used to complete as
/// HTTP 200: URLSession rewrites the CGI POST into a GET, drops the JSON
/// body, and the camera's HTML page then fails to decode. These tests pin
/// the redirect decision and a URLProtocol stub of that 301.
@Suite("CGI HTTP→HTTPS redirect", .serialized)
struct HTTPSRedirectTests {

    private func makeSession(followRedirects: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectURLProtocol.self]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        if followRedirects {
            return URLSession(configuration: config)
        }
        return URLSession(
            configuration: config,
            delegate: PinningTLSDelegate(policy: .alwaysAccept),
            delegateQueue: nil
        )
    }

    @Test("the CGI client refuses a 301 onto HTTPS instead of logging in")
    func refusedRedirectIsHTTPSRequired() async {
        RedirectURLProtocol.reset(behavior: .redirectToHTTPS)
        let session = makeSession(followRedirects: false)
        defer { session.finishTasksAndInvalidate() }
        let client = CGIClient(credentials: Self.httpCredentials, urlSession: session)
        await Self.expectHTTPSRequired(client)
        let counts = RedirectURLProtocol.snapshot()
        #expect(counts.httpPosts == 1)
        #expect(counts.httpsRequests == 0)
    }

    @Test("a followed 301 that returns HTML is still not a successful login")
    func followedRedirectIsNotLogin() async {
        RedirectURLProtocol.reset(behavior: .redirectToHTTPS)
        let session = makeSession(followRedirects: true)
        defer { session.finishTasksAndInvalidate() }
        let client = CGIClient(credentials: Self.httpCredentials, urlSession: session)
        await Self.expectHTTPSRequired(client)
        #expect(RedirectURLProtocol.snapshot().httpPosts == 1)
    }

    @Test("a normal JSON login still decodes when nothing redirects")
    func jsonLoginStillWorks() async throws {
        RedirectURLProtocol.reset(behavior: .loginJSON)
        let session = makeSession(followRedirects: false)
        defer { session.finishTasksAndInvalidate() }
        let client = CGIClient(credentials: Self.httpCredentials, urlSession: session)
        let token = try await client.login()
        #expect(token.name == "tok-redirect-test")
    }

    @Test("CGI redirects that would drop a POST are not followed")
    func cgiRedirectPolicy() {
        let http = URL(string: "http://127.0.0.1/cgi-bin/api.cgi")
        let https = URL(string: "https://127.0.0.1/cgi-bin/api.cgi")
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 301, to: https))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 302, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 303, to: https))
        #expect(HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 307, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 307, to: https))
        #expect(HTTPRedirectPolicy.shouldFollowCGIRedirect(from: https, status: 308, to: https))
    }

    @Test("media downloads follow same-scheme redirects and refuse a scheme change")
    func mediaRedirectPolicy() {
        let http = URL(string: "http://127.0.0.1/cgi-bin/api.cgi")
        let https = URL(string: "https://127.0.0.1/cgi-bin/api.cgi")
        #expect(HTTPRedirectPolicy.shouldFollowMediaRedirect(from: http, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowMediaRedirect(from: http, to: https))
        #expect(!HTTPRedirectPolicy.shouldFollowMediaRedirect(from: https, to: http))
        #expect(HTTPRedirectPolicy.mediaPayloadRejected(
            requestURL: http, statusCode: 301, responseURL: http, contentType: "text/html"
        ))
        #expect(HTTPRedirectPolicy.mediaPayloadRejected(
            requestURL: http, statusCode: 200, responseURL: https, contentType: "text/html"
        ))
        #expect(!HTTPRedirectPolicy.mediaPayloadRejected(
            requestURL: http, statusCode: 200, responseURL: https, contentType: "image/jpeg"
        ))
        #expect(!HTTPRedirectPolicy.mediaPayloadRejected(
            requestURL: https, statusCode: 206, responseURL: https, contentType: "video/mp4"
        ))
    }

    private static let httpCredentials = CameraCredentials(
        host: "127.0.0.1", port: 80, username: "admin", password: "secret", useHTTPS: false
    )

    private static func expectHTTPSRequired(_ client: CGIClient) async {
        do {
            _ = try await client.login()
            Issue.record("login succeeded on a redirect")
        } catch let error as ReolinkClientError {
            guard case .httpsRequired = error else {
                Issue.record("expected httpsRequired, got \(String(describing: error))")
                return
            }
            let text = error.localizedDescription
            #expect(text.contains("HTTPS"))
            #expect(!text.lowercased().contains("malformed"))
            #expect(!text.contains("127.0.0.1"))
            #expect(!text.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }
}

/// Returns 301 from HTTP POST, and an HTML page if a client follows it to HTTPS.
/// A `.loginJSON` mode returns a normal CGI login body so the decode path stays covered.
final class RedirectURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable { case redirectToHTTPS, case loginJSON }
    struct Counts: Sendable { var httpPosts = 0; var httpsRequests = 0 }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behavior: Behavior = .redirectToHTTPS
    nonisolated(unsafe) private static var counts = Counts()

    static func reset(behavior: Behavior) {
        lock.lock()
        self.behavior = behavior
        counts = Counts()
        lock.unlock()
    }

    static func snapshot() -> Counts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let scheme = request.url?.scheme?.lowercased() ?? ""
        let behavior = Self.currentBehavior()
        if scheme == "https" {
            Self.recordHTTPS()
        } else if method == "POST" {
            Self.recordHTTPPost()
        }

        let url = request.url ?? URL(string: "http://127.0.0.1/cgi-bin/api.cgi")!
        if behavior == .loginJSON, method == "POST" {
            let body = Data(#"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"tok-redirect-test"}}}]"#.utf8)
            finish(url: url, status: 200, headers: ["Content-Type": "application/json"], body: body)
            return
        }
        if scheme == "http", method == "POST" {
            finish(
                url: url,
                status: 301,
                headers: [
                    "Location": "https://127.0.0.1/cgi-bin/api.cgi?cmd=Login",
                    "Content-Type": "text/html"
                ],
                body: Data("<html>redirect</html>".utf8)
            )
            return
        }
        finish(
            url: url,
            status: 200,
            headers: ["Content-Type": "text/html"],
            body: Data("<html>camera</html>".utf8)
        )
    }

    override func stopLoading() {}

    private func finish(url: URL, status: Int, headers: [String: String], body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func currentBehavior() -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        return behavior
    }

    private static func recordHTTPPost() {
        lock.lock()
        counts.httpPosts += 1
        lock.unlock()
    }

    private static func recordHTTPS() {
        lock.lock()
        counts.httpsRequests += 1
        lock.unlock()
    }
}
