import Testing
import Foundation
@testable import ReolinkAPI

/// Edge cases around the HTTP→HTTPS decision and the CGI client's
/// handling of it. Every response comes from `ScriptedHTTPProtocol`;
/// nothing dials a camera.
@Suite("HTTPS redirect edge cases", .serialized)
struct HTTPSRedirectEdgeTests {

    private static let loginJSON = Data(
        #"[{"cmd":"Login","code":0,"value":{"Token":{"leaseTime":3600,"name":"tok-edge"}}}]"#.utf8
    )

    private static let credentials = CameraCredentials(
        host: "127.0.0.1", port: 80, username: "admin", password: "secret", useHTTPS: false
    )

    // MARK: Policy

    @Test func cgiRedirectKeepsThePostOnlyForSameScheme307And308() throws {
        let http = try Self.url("http://127.0.0.1/cgi-bin/api.cgi")
        let https = try Self.url("https://127.0.0.1/cgi-bin/api.cgi")
        #expect(HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 307, to: http))
        #expect(HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 308, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 308, to: https))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: http, status: 302, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowCGIRedirect(from: nil, status: 301, to: nil))
        #expect(HTTPRedirectPolicy.shouldFollowCGIRedirect(from: nil, status: 307, to: nil))
    }

    @Test func mediaRedirectFollowsOnlyWhenTheSchemeIsKnownAndUnchanged() throws {
        let http = try Self.url("http://127.0.0.1/cgi-bin/api.cgi")
        let https = try Self.url("https://127.0.0.1/cgi-bin/api.cgi")
        #expect(HTTPRedirectPolicy.shouldFollowMediaRedirect(from: nil, to: nil))
        #expect(HTTPRedirectPolicy.shouldFollowMediaRedirect(from: nil, to: http))
        #expect(HTTPRedirectPolicy.shouldFollowMediaRedirect(from: https, to: nil))
        #expect(HTTPRedirectPolicy.shouldFollowMediaRedirect(from: http, to: http))
        #expect(!HTTPRedirectPolicy.shouldFollowMediaRedirect(from: http, to: https))
    }

    @Test func cgiTreatsRedirectsHtmlAndSchemeUpgradesAsHTTPSRequired() throws {
        let http = try Self.url("http://127.0.0.1/cgi-bin/api.cgi")
        let https = try Self.url("https://127.0.0.1/cgi-bin/api.cgi")
        #expect(Self.cgiRequiresHTTPS(request: http, response: http, status: 301, type: "text/html"))
        #expect(Self.cgiRequiresHTTPS(request: http, response: http, status: 399, type: "application/json"))
        #expect(Self.cgiRequiresHTTPS(request: http, response: https, status: 200, type: "image/jpeg"))
        #expect(Self.cgiRequiresHTTPS(request: http, response: http, status: 200, type: "text/html; charset=utf-8"))
        #expect(!Self.cgiRequiresHTTPS(request: http, response: http, status: 200, type: "application/json"))
        #expect(!Self.cgiRequiresHTTPS(request: https, response: https, status: 200, type: "TEXT/HTML"))
        #expect(!Self.cgiRequiresHTTPS(request: http, response: http, status: 200, type: nil))
        #expect(!Self.cgiRequiresHTTPS(request: http, response: http, status: 500, type: "application/json"))
    }

    @Test func mediaKeepsARealImageAfterSchemeChangeAndDropsHtmlOrUnknownBytes() throws {
        let http = try Self.url("http://127.0.0.1/cgi-bin/api.cgi")
        let https = try Self.url("https://127.0.0.1/cgi-bin/api.cgi")
        #expect(!Self.mediaRejected(request: http, response: https, status: 200, type: "image/jpeg"))
        #expect(!Self.mediaRejected(request: http, response: https, status: 200, type: "VIDEO/MP4"))
        #expect(!Self.mediaRejected(request: http, response: https, status: 200, type: "application/octet-stream"))
        #expect(Self.mediaRejected(request: http, response: https, status: 200, type: "application/json"))
        #expect(Self.mediaRejected(request: http, response: https, status: 200, type: nil))
        #expect(Self.mediaRejected(request: http, response: http, status: 302, type: "image/jpeg"))
        #expect(Self.mediaRejected(request: https, response: https, status: 200, type: "Text/Html"))
        #expect(!Self.mediaRejected(request: https, response: https, status: 200, type: nil))
        #expect(!Self.mediaRejected(request: https, response: https, status: 206, type: "video/mp4"))
    }

    @Test func theErrorTextNamesHTTPSAndNothingElse() {
        let error = ReolinkClientError.httpsRequired
        #expect(error.description == "This camera requires HTTPS.")
        #expect(error.localizedDescription == "This camera requires HTTPS.")
        #expect(!error.description.contains("127.0.0.1"))
        #expect(!error.description.contains("secret"))
    }

    // MARK: Delegates

    @Test func cgiDelegateFollowsASameScheme307AndRefusesTheRest() throws {
        let delegate = PinningTLSDelegate(policy: .alwaysAccept)
        let kept = try redirection(
            follow: { session, task, response, next, completion in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next, completionHandler: completion)
            },
            from: "http://127.0.0.1/cgi-bin/api.cgi",
            status: 307,
            to: "http://127.0.0.1/cgi-bin/api.cgi?followed=1"
        )
        #expect(kept?.url?.query?.contains("followed=1") == true)

        let dropped = try redirection(
            follow: { session, task, response, next, completion in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next, completionHandler: completion)
            },
            from: "http://127.0.0.1/cgi-bin/api.cgi",
            status: 301,
            to: "https://127.0.0.1/cgi-bin/api.cgi"
        )
        #expect(dropped == nil)

        let sameScheme302 = try redirection(
            follow: { session, task, response, next, completion in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next, completionHandler: completion)
            },
            from: "http://127.0.0.1/cgi-bin/api.cgi",
            status: 302,
            to: "http://127.0.0.1/cgi-bin/api.cgi?moved=1"
        )
        #expect(sameScheme302 == nil)
    }

    @Test func mediaDelegateFollowsSameSchemeAndRefusesASchemeChange() throws {
        let delegate = MediaRedirectDelegate.shared
        let kept = try redirection(
            follow: { session, task, response, next, completion in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next, completionHandler: completion)
            },
            from: "http://127.0.0.1/cgi-bin/api.cgi?cmd=Snap",
            status: 302,
            to: "http://127.0.0.1/snap.jpg"
        )
        #expect(kept?.url?.absoluteString == "http://127.0.0.1/snap.jpg")

        let dropped = try redirection(
            follow: { session, task, response, next, completion in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next, completionHandler: completion)
            },
            from: "http://127.0.0.1/cgi-bin/api.cgi?cmd=Snap",
            status: 301,
            to: "https://127.0.0.1/snap.jpg"
        )
        #expect(dropped == nil)
    }

    // MARK: CGI client, stubbed transport

    @Test func aSameScheme307StillLogsIn() async throws {
        ScriptedHTTPProtocol.reset([
            .http(status: 307, headers: [
                "Location": "http://127.0.0.1/cgi-bin/api.cgi?cmd=Login&followed=1",
                "Content-Type": "text/html"
            ], body: Data("<html>redirect</html>".utf8)),
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON)
        ])
        let client = client(refusingRedirects: true)
        let token = try await client.login()
        #expect(token.name == "tok-edge")
        #expect(ScriptedHTTPProtocol.snapshot().count == 2)
    }

    @Test func a302IsHTTPSRequiredAndIsNotFollowed() async throws {
        ScriptedHTTPProtocol.reset([
            .http(status: 302, headers: [
                "Location": "http://127.0.0.1/cgi-bin/api.cgi?moved=1",
                "Content-Type": "text/html"
            ], body: Data("<html>redirect</html>".utf8))
        ])
        let client = client(refusingRedirects: true)
        await expectHTTPSRequired(client)
        #expect(ScriptedHTTPProtocol.snapshot().count == 1)
    }

    @Test func anHTMLPageWithStatus200IsHTTPSRequired() async throws {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>camera</html>".utf8))
        ])
        let client = client(refusingRedirects: true)
        await expectHTTPSRequired(client)
    }

    @Test func aTransportTimeoutSurfacesAsURLError() async {
        ScriptedHTTPProtocol.reset([.fail(.timedOut)])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded after a timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func anHTTPFailureCarriesTheStatusAndNotThePassword() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 503, headers: ["Content-Type": "text/plain"], body: Data("busy".utf8))
        ])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded on HTTP 503")
        } catch let error as ReolinkClientError {
            guard case .http(let status, let body) = error else {
                Issue.record("expected http, got \(String(describing: error))")
                return
            }
            #expect(status == 503)
            #expect(body == "busy")
            #expect(!error.description.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func anEmptyLoginEnvelopeIsAnEmptyResponse() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Data("[]".utf8))
        ])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded on an empty envelope")
        } catch let error as ReolinkClientError {
            guard case .emptyResponse = error else {
                Issue.record("expected emptyResponse, got \(String(describing: error))")
                return
            }
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func aNonJSONBodyIsMalformed() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Data("not-json".utf8))
        ])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded on a non-JSON body")
        } catch let error as ReolinkClientError {
            guard case .malformedResponse = error else {
                Issue.record("expected malformedResponse, got \(String(describing: error))")
                return
            }
            #expect(!error.description.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func aRejectedLoginIsLoginFailed() async {
        let body = Data(#"[{"cmd":"Login","code":1,"error":{"rspCode":-20,"detail":"rejected"}}]"#.utf8)
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: body)
        ])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded after the camera rejected it")
        } catch let error as ReolinkClientError {
            guard case .loginFailed(let cgi) = error else {
                Issue.record("expected loginFailed, got \(String(describing: error))")
                return
            }
            #expect(cgi?.rspCode == -20)
            #expect(!error.description.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func aNonHTTPResponseIsMalformed() async {
        ScriptedHTTPProtocol.reset([.nonHTTP])
        let client = client(refusingRedirects: false)
        do {
            _ = try await client.login()
            Issue.record("login succeeded on a non-HTTP response")
        } catch let error as ReolinkClientError {
            guard case .malformedResponse = error else {
                Issue.record("expected malformedResponse, got \(String(describing: error))")
                return
            }
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func snapshotReturnsBytesWhenTheCameraSendsAJPEG() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON),
            .http(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg)
        ])
        let client = client(refusingRedirects: true)
        let data = try await client.snapshotData(channel: 0)
        #expect(data == jpeg)
        let seen = ScriptedHTTPProtocol.snapshot()
        #expect(seen.count == 2)
        #expect(seen.last?.method == "GET")
    }

    @Test func snapshotRedirectIsHTTPSRequired() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON),
            .http(status: 301, headers: [
                "Location": "https://127.0.0.1/cgi-bin/api.cgi?cmd=Snap",
                "Content-Type": "text/html"
            ], body: Data("<html>redirect</html>".utf8))
        ])
        let client = client(refusingRedirects: true)
        do {
            _ = try await client.snapshotData(channel: 0)
            Issue.record("snapshot succeeded on a redirect")
        } catch let error as ReolinkClientError {
            guard case .httpsRequired = error else {
                Issue.record("expected httpsRequired, got \(String(describing: error))")
                return
            }
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
        #expect(ScriptedHTTPProtocol.snapshot().filter { $0.scheme == "https" }.isEmpty)
    }

    @Test func snapshotHTMLIsHTTPSRequired() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON),
            .http(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>camera</html>".utf8))
        ])
        let client = client(refusingRedirects: true)
        do {
            _ = try await client.snapshotData(channel: 1)
            Issue.record("snapshot succeeded on HTML")
        } catch let error as ReolinkClientError {
            guard case .httpsRequired = error else {
                Issue.record("expected httpsRequired, got \(String(describing: error))")
                return
            }
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func snapshotTimeoutIsATransportError() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON),
            .fail(.timedOut)
        ])
        let client = client(refusingRedirects: true)
        do {
            _ = try await client.snapshotData(channel: 0)
            Issue.record("snapshot succeeded after a timeout")
        } catch let error as ReolinkClientError {
            guard case .transport(let underlying) = error else {
                Issue.record("expected transport, got \(String(describing: error))")
                return
            }
            #expect((underlying as? URLError)?.code == .timedOut)
            #expect(!error.description.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func snapshotHTTPFailureCarriesTheStatus() async {
        ScriptedHTTPProtocol.reset([
            .http(status: 200, headers: ["Content-Type": "application/json"], body: Self.loginJSON),
            .http(status: 404, headers: ["Content-Type": "text/plain"], body: Data("missing".utf8))
        ])
        let client = client(refusingRedirects: true)
        do {
            _ = try await client.snapshotData(channel: 0)
            Issue.record("snapshot succeeded on HTTP 404")
        } catch let error as ReolinkClientError {
            guard case .http(let status, _) = error else {
                Issue.record("expected http, got \(String(describing: error))")
                return
            }
            #expect(status == 404)
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    @Test func theWrapperMatchesThePolicyForASchemeUpgrade() throws {
        let requestURL = try Self.url("http://127.0.0.1/cgi-bin/api.cgi?cmd=Login")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        let responseURL = try Self.url("https://127.0.0.1/cgi-bin/api.cgi?cmd=Login")
        let response = try #require(HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        ))
        #expect(CGIClient.httpsRequired(method: "POST", request: request, response: response))

        let same = try #require(HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        #expect(!CGIClient.httpsRequired(method: "POST", request: request, response: same))
    }

    // MARK: Helpers

    private func client(refusingRedirects: Bool) -> CGIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedHTTPProtocol.self]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        let session: URLSession
        if refusingRedirects {
            session = URLSession(
                configuration: config,
                delegate: PinningTLSDelegate(policy: .alwaysAccept),
                delegateQueue: nil
            )
        } else {
            session = URLSession(configuration: config)
        }
        return CGIClient(credentials: Self.credentials, urlSession: session)
    }

    private func expectHTTPSRequired(_ client: CGIClient) async {
        do {
            _ = try await client.login()
            Issue.record("login succeeded")
        } catch let error as ReolinkClientError {
            guard case .httpsRequired = error else {
                Issue.record("expected httpsRequired, got \(String(describing: error))")
                return
            }
            #expect(!error.description.contains("secret"))
        } catch {
            Issue.record("unexpected error \(String(describing: error))")
        }
    }

    private static func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private static func cgiRequiresHTTPS(request: URL, response: URL, status: Int, type: String?) -> Bool {
        HTTPRedirectPolicy.isHTTPSRequiredCGI(
            method: "POST",
            requestURL: request,
            statusCode: status,
            responseURL: response,
            contentType: type
        )
    }

    private static func mediaRejected(request: URL, response: URL, status: Int, type: String?) -> Bool {
        HTTPRedirectPolicy.mediaPayloadRejected(
            requestURL: request,
            statusCode: status,
            responseURL: response,
            contentType: type
        )
    }

    private func redirection(
        follow: (URLSession, URLSessionTask, HTTPURLResponse, URLRequest, @escaping @Sendable (URLRequest?) -> Void) -> Void,
        from original: String,
        status: Int,
        to redirected: String
    ) throws -> URLRequest? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let originalURL = try Self.url(original)
        let task = session.dataTask(with: URLRequest(url: originalURL))
        #expect(task.originalRequest?.url == originalURL)
        let response = try #require(HTTPURLResponse(
            url: originalURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirected]
        ))
        let next = URLRequest(url: try Self.url(redirected))
        let box = RedirectCapture()
        follow(session, task, response, next) { request in
            box.called = true
            box.request = request
        }
        #expect(box.called)
        return box.request
    }
}

private final class RedirectCapture: @unchecked Sendable {
    var called = false
    var request: URLRequest?
}

/// One-shot scripted HTTP. Each `startLoading` consumes the next step.
/// A session that follows a redirect issues another request and gets
/// the following step.
final class ScriptedHTTPProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var scheme: String
    }

    enum Step: Sendable {
        case http(status: Int, headers: [String: String], body: Data)
        case fail(URLError.Code)
        case nonHTTP
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Step] = []
    nonisolated(unsafe) private static var seen: [Seen] = []

    static func reset(_ steps: [Step]) {
        lock.lock()
        self.steps = steps
        seen = []
        lock.unlock()
    }

    static func snapshot() -> [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let scheme = request.url?.scheme?.lowercased() ?? ""
        Self.record(Seen(method: method, scheme: scheme))
        guard let step = Self.nextStep() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .nonHTTP:
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .http(let status, let headers, let body):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func nextStep() -> Step? {
        lock.lock()
        defer { lock.unlock() }
        guard !steps.isEmpty else { return nil }
        return steps.removeFirst()
    }

    private static func record(_ seen: Seen) {
        lock.lock()
        self.seen.append(seen)
        lock.unlock()
    }
}
