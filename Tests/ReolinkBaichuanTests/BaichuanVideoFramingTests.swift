import Testing
import Foundation
import ReolinkAPI
@testable import ReolinkBaichuan

@Suite("Baichuan preview framing")
struct BaichuanVideoFramingTests {

    private func client(_ transport: ScriptedTransport) -> BaichuanClient {
        BaichuanClient(
            credentials: BaichuanCredentials(host: "camera.local", username: "admin", password: "x"),
            transport: transport
        )
    }

    @Test func previewStartUsesVideoCommandWithoutAnExtension() async throws {
        let transport = ScriptedTransport()
        let camera = client(transport)
        let started = try await camera.startPreview(channel: 0, stream: .main)
        let sent = try #require(await transport.lastSent)
        #expect(started.msgNum == sent.header.msgNum)
        #expect(sent.header.msgID == BcMessageID.video)
        #expect(sent.header.msgClass == BcConstants.classModernWithOffset)
        #expect(sent.header.channelID == 0)
        #expect(sent.header.streamType == 0)
        #expect(sent.extensionBody == nil)
        let xml = String(data: sent.body, encoding: .utf8) ?? ""
        #expect(xml.contains("<streamType>mainStream</streamType>"))
        #expect(xml.contains("<handle>0</handle>"))
    }

    @Test func rejectedPreviewSurfacesAsAnError() async {
        let transport = ScriptedTransport()
        await transport.setReplyCode(400)
        let camera = client(transport)
        await #expect(throws: BaichuanError.self) {
            try await camera.startPreview(channel: 0, stream: .sub)
        }
    }

    @Test func livePreviewSendsStartThenStopOnTheSameMessageNumber() async throws {
        let transport = ScriptedTransport()
        let camera = client(transport)
        let frames = try await camera.liveVideoFrames(channel: 0, stream: .sub)
        for await _ in frames {}
        let sent = await transport.sent
        #expect(sent.count == 2)
        let start = try #require(sent.first)
        let stop = try #require(sent.last)
        #expect(start.header.msgID == BcMessageID.video)
        #expect(start.header.streamType == 1)
        #expect(start.extensionBody == nil)
        let startXML = String(data: start.body, encoding: .utf8) ?? ""
        #expect(startXML.contains("<handle>256</handle>"))
        #expect(startXML.contains("<streamType>subStream</streamType>"))
        #expect(stop.header.msgID == BcMessageID.videoStop)
        #expect(stop.header.msgNum == start.header.msgNum)
        let stopXML = String(data: stop.body, encoding: .utf8) ?? ""
        #expect(!stopXML.contains("streamType"))
    }

    @Test func enablingRTSPSendsNetPortCommand() async throws {
        let transport = ScriptedTransport()
        let camera = client(transport)
        try await camera.setRTSPEnabled(true)
        let sent = try #require(await transport.lastSent)
        #expect(sent.header.msgID == 36)
        #expect(sent.header.msgClass == BcConstants.classModernWithOffset)
        let xml = String(data: sent.body, encoding: .utf8) ?? ""
        #expect(xml.contains("<RtspPort version=\"1.1\">"))
        #expect(xml.contains("<enable>1</enable>"))
        #expect(!xml.contains("password"))
    }

    @Test func rejectedRTSPChangeThrows() async {
        let transport = ScriptedTransport()
        await transport.setReplyCode(400)
        let camera = client(transport)
        await #expect(throws: BaichuanError.self) {
            try await camera.setRTSPEnabled(true)
        }
    }

    @Test func pingReplyDoesNotWaitAndEchoesTheMessageNumber() async throws {
        let transport = ScriptedTransport()
        let camera = client(transport)
        let inbound = BcMessage(
            header: BcHeader(
                msgID: BcMessageID.ping,
                bodyLength: 0,
                channelID: 2,
                streamType: 1,
                msgNum: 44,
                responseCode: 0,
                msgClass: BcConstants.classModernWithOffset,
                payloadOffset: 0
            )
        )
        await camera.replyToPing(echoing: inbound)
        let sent = try #require(await transport.lastSent)
        #expect(sent.header.msgID == BcMessageID.ping)
        #expect(sent.header.responseCode == 200)
        #expect(sent.header.msgNum == 44)
        #expect(sent.header.channelID == 2)
        #expect(await transport.sent.count == 1)
    }

    @Test func keepalivePingIsCommand93() async throws {
        let transport = ScriptedTransport()
        let camera = client(transport)
        await camera.sendKeepalivePing()
        let sent = try #require(await transport.lastSent)
        #expect(sent.header.msgID == BcMessageID.ping)
        #expect(sent.header.responseCode == 0)
        #expect(sent.body.isEmpty)
    }
}
