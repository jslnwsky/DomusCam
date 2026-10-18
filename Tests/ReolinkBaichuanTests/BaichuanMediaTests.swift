import Testing
import Foundation
@testable import ReolinkBaichuan

@Suite("Baichuan live video")
struct BaichuanMediaTests {

    @Test func infoV1ReportsSizeAndFrameRate() {
        var parser = BaichuanMediaParser()
        let packets = parser.append(Self.infoV1(width: 2560, height: 1440, fps: 30))
        #expect(packets == [.info(width: 2560, height: 1440, fps: 30)])
    }

    @Test func iframeSplitsAnnexBAndPframeFollows() {
        let annex = Self.annexB(nals: [
            (start: [0x00, 0x00, 0x00, 0x01], nal: Data([0x67, 0x42])),
            (start: [0x00, 0x00, 0x00, 0x01], nal: Data([0x68, 0xCE])),
            (start: [0x00, 0x00, 0x01], nal: Data([0x65, 0x88]))
        ])
        let iframe = Self.video(
            magic: 0x6364_3030,
            codec: "H264",
            payload: annex,
            microseconds: 1_000
        )
        let pframe = Self.video(
            magic: 0x6364_3130,
            codec: "H265",
            payload: Data([0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            microseconds: 2_000
        )
        var parser = BaichuanMediaParser()
        let packets = parser.append(iframe + pframe)
        #expect(packets.count == 2)
        guard case .video(let first) = packets[0], case .video(let second) = packets[1] else {
            Issue.record("expected two video packets")
            return
        }
        #expect(first.codec == .h264)
        #expect(first.isKeyFrame)
        #expect(first.nalUnits == [Data([0x67, 0x42]), Data([0x68, 0xCE]), Data([0x65, 0x88])])
        #expect(first.microseconds == 1_000)
        #expect(first.rtpTimestamp == 90)
        #expect(second.codec == .h265)
        #expect(!second.isKeyFrame)
        #expect(second.nalUnits == [Data([0x02, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])])
    }

    @Test func partialChunkCompletesOnTheNextAppend() {
        let frame = Self.video(
            magic: 0x6364_3030,
            codec: "H264",
            payload: Data([0x65, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]),
            microseconds: 50
        )
        var parser = BaichuanMediaParser()
        #expect(parser.append(frame.prefix(10)).isEmpty)
        let packets = parser.append(frame.dropFirst(10))
        #expect(packets.count == 1)
        guard case .video(let video) = packets[0] else {
            Issue.record("expected a video packet")
            return
        }
        #expect(video.nalUnits == [Data([0x65, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])])
    }

    @Test func audioBetweenFramesIsSkipped() {
        let iframe = Self.video(
            magic: 0x6364_3030,
            codec: "H264",
            payload: Data(repeating: 0x65, count: 8),
            microseconds: 10
        )
        let pframe = Self.video(
            magic: 0x6364_3130,
            codec: "H264",
            payload: Data(repeating: 0x41, count: 8),
            microseconds: 20
        )
        var parser = BaichuanMediaParser()
        let packets = parser.append(iframe + Self.aac(Data(repeating: 0xAB, count: 8)) + pframe)
        let videos = packets.compactMap { packet -> BaichuanVideoFrame? in
            if case .video(let frame) = packet { return frame }
            return nil
        }
        #expect(videos.count == 2)
        #expect(videos[0].isKeyFrame)
        #expect(videos[1].nalUnits == [Data(repeating: 0x41, count: 8)])
    }

    @Test func payloadPaddingDoesNotEatTheNextPacket() {
        // 3-byte payload needs 5 pad bytes. The following info packet must
        // still land on its magic.
        let frame = Self.video(
            magic: 0x6364_3030,
            codec: "H264",
            payload: Data([0x65, 0x01, 0x02]),
            microseconds: 1
        )
        var parser = BaichuanMediaParser()
        let packets = parser.append(frame + Self.infoV1(width: 640, height: 360, fps: 15))
        #expect(packets.count == 2)
        #expect(packets[1] == .info(width: 640, height: 360, fps: 15))
    }

    @Test func previewAndRtspXML() {
        let start = String(data: BaichuanClient.buildPreviewXML(channel: 0, handle: 256, streamName: "subStream"), encoding: .utf8) ?? ""
        #expect(start.contains("<Preview version=\"1.1\">"))
        #expect(start.contains("<channelId>0</channelId>"))
        #expect(start.contains("<handle>256</handle>"))
        #expect(start.contains("<streamType>subStream</streamType>"))

        let stop = String(data: BaichuanClient.buildPreviewXML(channel: 0, handle: 0, streamName: nil), encoding: .utf8) ?? ""
        #expect(!stop.contains("streamType"))

        let rtsp = String(data: BaichuanClient.buildServicePortXML(service: "Rtsp", enabled: true), encoding: .utf8) ?? ""
        #expect(rtsp.contains("<RtspPort version=\"1.1\">"))
        #expect(rtsp.contains("<enable>1</enable>"))
        let params = BaichuanClient.previewParameters(for: .main)
        #expect(params.name == "mainStream")
        #expect(params.handle == 0)
        #expect(params.streamCode == 0)
    }

    @Test func plaintextMediaIsNotDecryptedAway() {
        let media = Self.infoV1(width: 320, height: 240, fps: 10)
        let header = BcHeader(
            msgID: BcMessageID.video,
            bodyLength: UInt32(media.count),
            msgNum: 7,
            responseCode: 200,
            msgClass: BcConstants.classModern,
            payloadOffset: nil
        )
        let wire = header.encode() + media
        let decoded = BcMessage.decode(from: wire, cipher: .bcEncrypt)?.0
        #expect(decoded?.body == media)
    }

    @Test func encryptedMediaStillDecrypts() {
        let media = Self.infoV1(width: 320, height: 240, fps: 10)
        let encrypted = BcCipher.bcEncrypt.encrypt(media, encOffset: 0)
        let header = BcHeader(
            msgID: BcMessageID.video,
            bodyLength: UInt32(encrypted.count),
            msgNum: 8,
            responseCode: 200,
            msgClass: BcConstants.classModern,
            payloadOffset: nil
        )
        let decoded = BcMessage.decode(from: header.encode() + encrypted, cipher: .bcEncrypt)?.0
        #expect(decoded?.body == media)
    }

    // MARK: - Fixtures (Neolink `bcmedia` layout)

    private static func infoV1(width: UInt32, height: UInt32, fps: UInt8) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x3130_3031))
        data.appendLE(UInt32(32))
        data.appendLE(width)
        data.appendLE(height)
        data.append(0)
        data.append(fps)
        data.append(contentsOf: Data(repeating: 0, count: 12))
        data.appendLE(UInt16(0))
        return data
    }

    private static func video(magic: UInt32, codec: String, payload: Data, microseconds: UInt32) -> Data {
        var data = Data()
        data.appendLE(magic)
        data.append(contentsOf: Data(codec.utf8))
        data.appendLE(UInt32(payload.count))
        data.appendLE(UInt32(0))
        data.appendLE(microseconds)
        data.appendLE(UInt32(0))
        data.append(payload)
        let pad = (8 - (payload.count % 8)) % 8
        if pad > 0 { data.append(contentsOf: Data(repeating: 0, count: pad)) }
        return data
    }

    private static func aac(_ payload: Data) -> Data {
        var data = Data()
        data.appendLE(UInt32(0x6277_3530))
        data.appendLE(UInt16(payload.count))
        data.appendLE(UInt16(payload.count))
        data.append(payload)
        let pad = (8 - (payload.count % 8)) % 8
        if pad > 0 { data.append(contentsOf: Data(repeating: 0, count: pad)) }
        return data
    }

    private static func annexB(nals: [(start: [UInt8], nal: Data)]) -> Data {
        var data = Data()
        for item in nals {
            data.append(contentsOf: item.start)
            data.append(item.nal)
        }
        return data
    }
}
