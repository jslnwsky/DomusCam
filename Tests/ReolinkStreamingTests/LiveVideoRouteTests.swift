import Testing
@testable import ReolinkStreaming

@Suite("Live video route when RTSP is closed")
struct LiveVideoRouteTests {

    @Test func openPortUsesRTSPEvenOnTheBaichuanControlPlane() {
        #expect(LiveVideoRoute.choose(usingBaichuanControl: true, rtspPortOpen: true) == .rtsp)
        #expect(LiveVideoRoute.choose(usingBaichuanControl: false, rtspPortOpen: true) == .rtsp)
    }

    @Test func closedPortOnBaichuanUsesThePreview() {
        #expect(LiveVideoRoute.choose(usingBaichuanControl: true, rtspPortOpen: false) == .baichuan)
    }

    @Test func closedPortWithoutBaichuanFailsFast() {
        #expect(LiveVideoRoute.choose(usingBaichuanControl: false, rtspPortOpen: false) == .rtspOff)
        #expect(RTSPStartDecision.shouldTryCandidates(portOpen: true))
        #expect(!RTSPStartDecision.shouldTryCandidates(portOpen: false))
        #expect(RTSPStartDecision.offMessage == "RTSP is off on this camera")
        #expect(LiveVideoPlayer.rtspOffMessage == RTSPStartDecision.offMessage)
    }
}
