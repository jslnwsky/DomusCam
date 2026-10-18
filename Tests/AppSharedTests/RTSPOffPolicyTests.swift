import Testing
@testable import AppShared

@Suite("No web traffic when the camera is not listening")
struct RTSPOffPolicyTests {

    @Test func webProbeRequiresAnAcceptingPort() {
        #expect(CameraDiscovery.shouldIssueWebProbe(tcpPortAcceptsConnections: true))
        #expect(!CameraDiscovery.shouldIssueWebProbe(tcpPortAcceptsConnections: false))
    }

    @Test func baichuanControlSkipsTheWebAPI() {
        #expect(!CameraSession.shouldPollWebAPI(usingBaichuanControl: true))
        #expect(CameraSession.shouldPollWebAPI(usingBaichuanControl: false))
    }
}
