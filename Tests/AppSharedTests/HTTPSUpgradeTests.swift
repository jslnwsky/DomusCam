import Testing
import Foundation
import ReolinkAPI
@testable import AppShared

/// HTTP→HTTPS recovery: classify the redirect, prefer a confirmed HTTPS
/// discovery hit, persist the upgrade, and keep HTTP-only cameras on HTTP.
@Suite("HTTPS upgrade and discovery preference")
struct HTTPSUpgradeTests {

    @Test("a redirect is 'requires HTTPS', not a malformed response")
    func httpsRequiredMessage() {
        let message = CameraSession.connectionFailureMessage(for: ReolinkClientError.httpsRequired)
        #expect(message == ConnectFailureMessage.httpsRequired)
        #expect(message.contains("requires HTTPS"))
        #expect(message.contains("Edit Connection"))
        #expect(!message.lowercased().contains("malformed"))
        #expect(!message.contains("://"))
        #expect(!message.contains("192.168"))
        #expect(!message.contains("admin"))
    }

    @Test("a 3xx HTTP status is the same HTTPS-required failure")
    func httpRedirectStatus() {
        let error = ReolinkClientError.http(status: 301, body: "<html></html>")
        #expect(CameraSession.suggestsHTTPSRequired(error))
        #expect(CameraSession.httpsUpgradeIsSticky(error))
        let message = ConnectFailureMessage.text(for: error)
        #expect(message.contains("requires HTTPS"))
        #expect(!message.contains("<html>"))
    }

    @Test("a refused HTTP port and a redirect both upgrade; a missing host does not")
    func upgradeDecision() {
        let redirect = ReolinkClientError.httpsRequired
        let refused = URLError(.cannotConnectToHost)
        let timeout = URLError(.timedOut)
        let malformed = ReolinkClientError.malformedResponse("html")
        let missing = URLError(.cannotFindHost)
        let auth = ReolinkClientError.http(status: 401, body: nil)
        let cancelled = URLError(.cancelled)

        #expect(CameraSession.shouldAttemptHTTPSUpgrade(redirect))
        #expect(CameraSession.httpsUpgradeIsSticky(redirect))
        #expect(CameraSession.shouldAttemptHTTPSUpgrade(refused))
        #expect(CameraSession.httpsUpgradeIsSticky(refused))
        #expect(CameraSession.shouldAttemptHTTPSUpgrade(timeout))
        #expect(!CameraSession.httpsUpgradeIsSticky(timeout))
        #expect(CameraSession.shouldAttemptHTTPSUpgrade(malformed))
        #expect(!CameraSession.httpsUpgradeIsSticky(malformed))
        #expect(CameraSession.shouldAttemptHTTPSUpgrade(cancelled))
        #expect(!CameraSession.httpsUpgradeIsSticky(cancelled))
        #expect(!CameraSession.shouldAttemptHTTPSUpgrade(missing))
        #expect(!CameraSession.shouldAttemptHTTPSUpgrade(auth))
        #expect(!CameraSession.suggestsHTTPSRequired(malformed))
    }

    @Test("a successful upgrade persists HTTPS on port 443 and keeps the fingerprint")
    func persistUpgrade() {
        var entry = CameraEntry(
            displayName: "Porch",
            host: "192.168.1.20",
            port: 80,
            username: "admin",
            useHTTPS: false,
            tlsFingerprint: "pin",
            controlTransport: .http
        )
        entry.channelOrder = [2, 1]
        let upgraded = entry.applyingSuccessfulHTTPSUpgrade()
        #expect(upgraded.id == entry.id)
        #expect(upgraded.displayName == "Porch")
        #expect(upgraded.host == "192.168.1.20")
        #expect(upgraded.port == 443)
        #expect(upgraded.useHTTPS)
        #expect(upgraded.controlTransport == .https)
        #expect(upgraded.tlsFingerprint == "pin")
        #expect(upgraded.channelOrder == [2, 1])
        #expect(upgraded.applyingSuccessfulHTTPSUpgrade() == upgraded)
    }

    @Test("editing connection keeps Baichuan when the address is unchanged")
    func editKeepsBaichuanAndOtherFields() {
        var entry = CameraEntry(
            displayName: "CX410",
            host: "192.168.1.77",
            port: 80,
            username: "admin",
            tlsFingerprint: "pin",
            controlTransport: .baichuan
        )
        entry.hiddenAppBadgeChannels = [1]
        let sameAddress = entry.applyingConnectionEdit(
            host: "192.168.1.77", port: 80, username: "admin", useHTTPS: false
        )
        #expect(sameAddress.controlTransport == .baichuan)
        #expect(sameAddress.tlsFingerprint == "pin")
        #expect(sameAddress.hiddenAppBadgeChannels == [1])

        let https = entry.applyingConnectionEdit(
            host: "192.168.1.77", port: 443, username: "admin", useHTTPS: true
        )
        #expect(https.useHTTPS)
        #expect(https.port == 443)
        #expect(https.controlTransport == .https)
        #expect(https.displayName == "CX410")
    }

    @Test("editing a camera does not flag it as a duplicate of itself")
    func editExcludesSelfFromDuplicateCheck() {
        let id = UUID()
        let existing = CameraEntry(
            id: id, displayName: "Porch", host: "192.168.1.20", port: 80, username: "admin"
        )
        let draft = CameraEntryDraft(
            displayName: "Porch", host: "192.168.1.20", port: "80", username: "admin", useHTTPS: true
        )
        guard case .valid(let edited) = draft.validate(existing: [existing], excluding: id) else {
            Issue.record("editing the same camera should validate")
            return
        }
        #expect(edited.useHTTPS)
        #expect(edited.port == 80)
        let duplicate = draft.validate(existing: [existing])
        if case .invalid(let errors) = duplicate {
            #expect(errors[.host]?.contains("already added") == true)
        } else {
            Issue.record("a second camera at the same address should be rejected")
        }
    }

    @Test("confirmed HTTPS wins over confirmed HTTP, and HTTP-only stays HTTP")
    func discoveryPrefersHTTPS() {
        let http = device(port: 80, confirmed: true, transport: .http)
        let https = device(port: 443, confirmed: true, transport: .https)
        let both = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.20", webHits: [http, https], baichuanConfirmed: false
        )
        #expect(both?.controlTransport == .https)
        #expect(both?.port == 443)

        let onlyHTTP = CameraDiscovery.resolveDiscovery(
            host: "192.168.1.20", webHits: [http], baichuanConfirmed: false
        )
        #expect(onlyHTTP?.controlTransport == .http)
        #expect(onlyHTTP?.port == 80)
    }

    @Test("an HTTP 301 or an HTML page is not a discovery hit; CGI JSON is")
    func probeClassification() {
        let redirect = CameraDiscovery.deviceFromProbe(
            host: "192.168.1.20", port: 80, requestedScheme: "http",
            statusCode: 301, body: "", contentType: "text/html"
        )
        #expect(redirect == nil)

        let html = CameraDiscovery.deviceFromProbe(
            host: "192.168.1.20", port: 80, requestedScheme: "http",
            statusCode: 200, body: "<html>login</html>", contentType: "text/html"
        )
        #expect(html == nil)

        let followed = CameraDiscovery.deviceFromProbe(
            host: "192.168.1.20", port: 80, requestedScheme: "http",
            statusCode: 200,
            body: #"[{"cmd":"GetDevInfo","error":{"rspCode":-6}}]"#,
            contentType: "application/json",
            finalScheme: "https"
        )
        #expect(followed == nil)

        let http = CameraDiscovery.deviceFromProbe(
            host: "192.168.1.20", port: 80, requestedScheme: "http",
            statusCode: 200,
            body: #"[{"cmd":"GetDevInfo","error":{"rspCode":-6}}]"#,
            contentType: "application/json",
            finalScheme: "http"
        )
        #expect(http?.confirmedReolink == true)
        #expect(http?.controlTransport == .http)

        let https = CameraDiscovery.deviceFromProbe(
            host: "192.168.1.20", port: 443, requestedScheme: "https",
            statusCode: 200,
            body: #"[{"cmd":"GetDevInfo","error":{"rspCode":-6}}]"#,
            contentType: "application/json"
        )
        #expect(https?.controlTransport == .https)
        #expect(https?.port == 443)
    }

    @Test("adding a discovered camera uses HTTPS only when 443 answered")
    func preferredAddConnection() {
        let https = PreferredCameraConnection(discoveredPort: 443, transport: .https)
        #expect(https.useHTTPS)
        #expect(https.port == 443)
        let http = PreferredCameraConnection(discoveredPort: 80, transport: .http)
        #expect(!http.useHTTPS)
        #expect(http.port == 80)
        let baichuan = PreferredCameraConnection(discoveredPort: 9000, transport: .baichuan)
        #expect(!baichuan.useHTTPS)
        #expect(baichuan.port == 80)
        #expect(baichuan.controlTransport == .baichuan)
    }

    private func device(port: Int, confirmed: Bool, transport: ControlTransport) -> DiscoveredDevice {
        DiscoveredDevice(
            host: "192.168.1.20",
            port: port,
            displayName: "192.168.1.20",
            kindHint: "Reolink",
            confirmedReolink: confirmed,
            controlTransport: transport
        )
    }
}
