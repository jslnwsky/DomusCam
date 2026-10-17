import Foundation
import OSLog
import ReolinkAPI

private let log = Logger(subsystem: "com.75-c.DomusCam.baichuan", category: "video")

/// First-frame latch shared by the preview reader and its idle deadline.
private final class DeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
    /// Returns true the first time it is called.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension BaichuanClient {

    /// Parameters the official client sends with a Preview start.
    /// Handles differ by stream; the header stream byte is a separate code.
    public static func previewParameters(for stream: StreamKind) -> (name: String, handle: Int, streamCode: UInt8) {
        switch stream {
        case .main:
            return ("mainStream", 0, 0)
        case .sub:
            return ("subStream", 256, 1)
        case .ext:
            return ("externStream", 1024, 0)
        }
    }

    /// `<Preview>` body. `streamName == nil` is the stop command, which
    /// omits `<streamType>`.
    public static func buildPreviewXML(channel: Int, handle: Int, streamName: String?) -> Data {
        let streamTag = streamName.map { "<streamType>\($0)</streamType>\n" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Preview version="1.1">
        <channelId>\(channel)</channelId>
        <handle>\(handle)</handle>
        \(streamTag)</Preview>
        </body>

        """
        return Data(xml.utf8)
    }

    /// `<RtspPort><enable>` body for cmd_id 36. The tag is the service name
    /// with a `Port` suffix, matching the camera's net-port setting.
    public static func buildServicePortXML(service: String, enabled: Bool) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <\(service)Port version="1.1">
        <enable>\(enabled ? 1 : 0)</enable>
        </\(service)Port>
        </body>

        """
        return Data(xml.utf8)
    }

    /// A preview that has been accepted. `msgNum` is reused for the stop
    /// command so the camera can match it to the stream it just started.
    public struct PreviewStart: Sendable {
        public let channelID: UInt8
        public let stream: StreamKind
        public let msgNum: UInt16
        public let replyBody: Data
    }

    /// Ask the camera to start sending live video on this connection.
    /// The binary frames arrive afterwards as msg_id 3 pushes.
    @discardableResult
    public func startPreview(channel: UInt8, stream: StreamKind) async throws -> PreviewStart {
        let params = Self.previewParameters(for: stream)
        let msgNum = await nextMessageNumber()
        let body = Self.buildPreviewXML(channel: Int(channel), handle: params.handle, streamName: params.name)
        log.info("Baichuan preview start stream=\(params.name, privacy: .public) channel=\(channel, privacy: .public)")
        let reply = try await sendPreview(
            msgID: BcMessageID.video,
            channel: channel,
            streamCode: params.streamCode,
            msgNum: msgNum,
            body: body,
            stage: "previewStart"
        )
        let accepted = reply.header.responseCode == 200 || Self.looksLikeMedia(reply.body)
        guard accepted else {
            throw BaichuanError.unexpectedReply(msgID: reply.header.msgID, code: reply.header.responseCode)
        }
        return PreviewStart(channelID: channel, stream: stream, msgNum: msgNum, replyBody: reply.body)
    }

    public func stopPreview(_ start: PreviewStart) async {
        let params = Self.previewParameters(for: start.stream)
        let body = Self.buildPreviewXML(channel: Int(start.channelID), handle: params.handle, streamName: nil)
        _ = try? await sendPreview(
            msgID: BcMessageID.videoStop,
            channel: start.channelID,
            streamCode: params.streamCode,
            msgNum: start.msgNum,
            body: body,
            stage: "previewStop"
        )
    }

    /// Live H.264/H.265 access units from the camera's port-9000 preview.
    /// Dropping the stream sends Preview stop. Audio is parsed and discarded.
    ///
    /// The start command is sent without a reply slot. Video frames reuse
    /// that message number, and a slot would keep the first of them (and
    /// drop the rest until the XML ack is taken).
    public func liveVideoFrames(channel: UInt8, stream: StreamKind) async throws -> AsyncStream<BaichuanVideoFrame> {
        let messages = await subscribe()
        let params = Self.previewParameters(for: stream)
        let msgNum = await nextMessageNumber()
        let body = Self.buildPreviewXML(channel: Int(channel), handle: params.handle, streamName: params.name)
        log.info("Baichuan preview start stream=\(params.name, privacy: .public) channel=\(channel, privacy: .public)")
        try await sendPreview(
            msgID: BcMessageID.video,
            channel: channel,
            streamCode: params.streamCode,
            msgNum: msgNum,
            body: body,
            stage: "previewStart",
            awaitReply: false
        )
        let started = PreviewStart(channelID: channel, stream: stream, msgNum: msgNum, replyBody: Data())
        let (frames, continuation) = AsyncStream<BaichuanVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(90)
        )
        let stopOnce = DeliveryFlag()
        let task = Task {
            var parser = BaichuanMediaParser()
            let delivered = DeliveryFlag()
            let giveUp = Task {
                try? await Task.sleep(for: .seconds(6))
                // Cancellation ends the sleep early. Only the idle deadline
                // should close the stream; the reader closes it on exit.
                if Task.isCancelled { return }
                if !delivered.isSet {
                    log.warning("Baichuan preview produced no video frame")
                    continuation.finish()
                }
            }
            func emit(_ body: Data) {
                if body.first == UInt8(ascii: "<") { return }
                for packet in parser.append(body) {
                    if case .video(let frame) = packet, !frame.nalUnits.isEmpty {
                        delivered.set()
                        giveUp.cancel()
                        continuation.yield(frame)
                    }
                }
            }
            for await message in messages {
                if Task.isCancelled { break }
                guard message.header.msgID == BcMessageID.video else { continue }
                if message.header.msgNum == msgNum,
                   message.header.responseCode != 0,
                   message.header.responseCode != 200,
                   !Self.looksLikeMedia(message.body) {
                    log.warning("Baichuan preview rejected code=\(message.header.responseCode, privacy: .public)")
                    break
                }
                emit(message.body)
            }
            giveUp.cancel()
            if stopOnce.claim() {
                await self.stopPreview(started)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task {
                if stopOnce.claim() {
                    await self.stopPreview(started)
                }
            }
        }
        return frames
    }

    /// Proactive idle ping (cmd_id 93). Cameras close a quiet port-9000
    /// session after about 30 seconds; this is the packet their own apps send.
    public func sendKeepalivePing() async {
        let msgNum = await nextMessageNumber()
        let header = BcHeader(
            msgID: BcMessageID.ping,
            bodyLength: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        do {
            _ = try await sendAndAwait(BcMessage(header: header, body: Data()), timeout: 4, stage: "ping")
        } catch {
            log.debug("Baichuan keepalive ping failed")
        }
    }

    /// Answer a camera-initiated ping without waiting for a further reply.
    /// Registering a reply slot here would swallow the next message that
    /// reuses this message number.
    public func replyToPing(echoing message: BcMessage) async {
        let header = BcHeader(
            msgID: BcMessageID.ping,
            bodyLength: 0,
            channelID: message.header.channelID,
            streamType: message.header.streamType,
            msgNum: message.header.msgNum,
            responseCode: 200,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        do {
            try await send(BcMessage(header: header, body: Data()))
        } catch {
            log.debug("Baichuan ping reply failed")
        }
    }

    /// Turn the camera's RTSP service on or off (cmd_id 36, `<RtspPort>`).
    /// The web ports are a different setting and stay as they are.
    public func setRTSPEnabled(_ enabled: Bool) async throws {
        let msgNum = await nextMessageNumber()
        let body = Self.buildServicePortXML(service: "Rtsp", enabled: enabled)
        log.info("Baichuan set RTSP enabled=\(enabled, privacy: .public)")
        let header = BcHeader(
            msgID: 36,
            bodyLength: 0,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let reply = try await sendAndAwait(BcMessage(header: header, body: body), timeout: 8, stage: "setRtsp")
        guard reply.header.responseCode == 200 else {
            throw BaichuanError.unexpectedReply(msgID: reply.header.msgID, code: reply.header.responseCode)
        }
    }

    static func looksLikeMedia(_ body: Data) -> Bool {
        guard body.count >= 4 else { return false }
        return BaichuanMediaParser.isMediaMagic(body.readLE(at: 0, as: UInt32.self))
    }

    private func sendPreview(
        msgID: UInt32,
        channel: UInt8,
        streamCode: UInt8,
        msgNum: UInt16,
        body: Data,
        stage: String,
        awaitReply: Bool = true
    ) async throws -> BcMessage {
        let header = BcHeader(
            msgID: msgID,
            bodyLength: 0,
            channelID: channel,
            streamType: streamCode,
            msgNum: msgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let message = BcMessage(header: header, body: body)
        if awaitReply {
            return try await sendAndAwait(message, timeout: 8, stage: stage)
        }
        try await send(message)
        return message
    }
}
