import Foundation

/// Decisions for HTTP redirects on the way to a Reolink camera.
///
/// A 301/302/303 turns a CGI `POST` into a `GET` and drops the JSON body.
/// URLSession then delivers the camera's HTML page with status 200, which
/// decodes as a malformed API response. Authenticated calls must not follow
/// that redirect. They reconnect on HTTPS with the normal trust-on-first-use
/// pin instead. Media downloads may follow a redirect that stays on the same
/// scheme; a scheme change is refused so a self-signed certificate is never
/// accepted by the default trust store.
public enum HTTPRedirectPolicy {

    /// CGI control-plane redirects. Same-scheme 307/308 keep the POST body
    /// and are safe to follow. Everything else — including HTTP→HTTPS — is
    /// refused so the caller sees the 3xx and can switch transports.
    public static func shouldFollowCGIRedirect(
        from original: URL?,
        status: Int,
        to redirected: URL?
    ) -> Bool {
        guard scheme(of: original) == scheme(of: redirected) else { return false }
        return status == 307 || status == 308
    }

    /// Snapshot and recording GETs. Follow only when the scheme does not change.
    public static func shouldFollowMediaRedirect(from original: URL?, to redirected: URL?) -> Bool {
        let from = scheme(of: original)
        let to = scheme(of: redirected)
        if from == nil || to == nil { return true }
        return from == to
    }

    /// A CGI response that must not be decoded as JSON. Covers a refused
    /// redirect (3xx) and a redirect URLSession already followed (final URL
    /// is HTTPS, or the body is the camera's HTML page).
    public static func isHTTPSRequiredCGI(
        method: String?,
        requestURL: URL?,
        statusCode: Int,
        responseURL: URL?,
        contentType: String?
    ) -> Bool {
        if (300..<400).contains(statusCode) { return true }
        let requested = scheme(of: requestURL)
        if requested == "http", scheme(of: responseURL) == "https" { return true }
        if requested == "http", isHTML(contentType) { return true }
        _ = method
        return false
    }

    /// A media response that must not be saved as a snapshot or recording.
    /// A followed HTTP→HTTPS redirect that actually returned an image or
    /// video is kept; HTML and 3xx responses are not.
    public static func mediaPayloadRejected(
        requestURL: URL?,
        statusCode: Int,
        responseURL: URL?,
        contentType: String?
    ) -> Bool {
        if (300..<400).contains(statusCode) { return true }
        if isHTML(contentType) { return true }
        let requested = scheme(of: requestURL)
        let final = scheme(of: responseURL)
        if requested == "http", final == "https", !isMedia(contentType) { return true }
        return false
    }

    private static func scheme(of url: URL?) -> String? {
        url?.scheme?.lowercased()
    }

    private static func isHTML(_ contentType: String?) -> Bool {
        contentType?.lowercased().contains("text/html") == true
    }

    private static func isMedia(_ contentType: String?) -> Bool {
        let type = contentType?.lowercased() ?? ""
        return type.contains("image/")
            || type.contains("video/")
            || type.contains("application/octet-stream")
    }
}

/// URLSession delegate for snapshot and recording downloads. Refuses a
/// redirect that changes scheme so those requests fail as "HTTPS required"
/// instead of trusting a certificate the CGI client would have pinned, or
/// saving the camera's HTML page as media.
public final class MediaRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = MediaRedirectDelegate()

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let follow = HTTPRedirectPolicy.shouldFollowMediaRedirect(
            from: task.originalRequest?.url,
            to: request.url
        )
        completionHandler(follow ? request : nil)
    }
}
