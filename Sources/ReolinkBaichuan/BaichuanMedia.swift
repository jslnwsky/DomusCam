import Foundation

/// One decoded unit from a Baichuan live-video byte stream.
///
/// The camera wraps H.264/H.265 in its own framing (`BcMedia` in Neolink):
/// an info header, then I-frames (`00dc`…) and P-frames (`01dc`…), with AAC
/// or ADPCM audio mixed in. This parser only surfaces video. Audio is
/// consumed so the next frame stays aligned.
public enum BaichuanMediaPacket: Sendable, Equatable {
    case info(width: Int, height: Int, fps: Int)
    case video(BaichuanVideoFrame)
}

public struct BaichuanVideoFrame: Sendable, Equatable {
    public enum Codec: Sendable, Equatable {
        case h264
        case h265
    }

    public let codec: Codec
    /// Annex-B start codes removed. Each element is one NAL, including its
    /// one- or two-byte header, which is what the existing sample-buffer
    /// assemblers consume.
    public let nalUnits: [Data]
    public let isKeyFrame: Bool
    /// Camera clock, microseconds. Zero when the header omitted it.
    public let microseconds: UInt32

    /// 90 kHz timestamp for the display-layer clock. Truncation is fine:
    /// the assembler only needs consecutive frames to differ.
    public var rtpTimestamp: UInt32 {
        UInt32(truncatingIfNeeded: (UInt64(microseconds) &* 90) / 1000)
    }
}

/// Incremental `BcMedia` parser. Feed decrypted video-message bodies; it
/// returns every complete packet and keeps a partial tail for the next chunk.
public struct BaichuanMediaParser: Sendable {
    private var buffer = Data()
    private var cursor = 0

    public init() {}

    public static func isMediaMagic(_ magic: UInt32) -> Bool {
        switch magic {
        case Magic.infoV1, Magic.infoV2:
            return true
        case Magic.iframeFirst...Magic.iframeLast:
            return true
        case Magic.pframeFirst...Magic.pframeLast:
            return true
        case Magic.aac, Magic.adpcm:
            return true
        default:
            return false
        }
    }

    /// Split an Annex-B access unit into raw NAL units. A payload with no
    /// start code is returned as a single NAL (some firmware omits them).
    public static func nalUnits(annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var markers: [Int] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                markers.append(index)
                index += 3
                continue
            }
            if index + 3 < bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                markers.append(index)
                index += 4
                continue
            }
            index += 1
        }
        guard !markers.isEmpty else {
            return annexB.isEmpty ? [] : [annexB]
        }
        var units: [Data] = []
        for (offset, marker) in markers.enumerated() {
            let nalStart = bytes[marker + 2] == 1 ? marker + 3 : marker + 4
            let nalEnd = offset + 1 < markers.count ? markers[offset + 1] : bytes.count
            if nalStart < nalEnd {
                units.append(Data(bytes[nalStart..<nalEnd]))
            }
        }
        return units
    }

    public mutating func append(_ data: Data) -> [BaichuanMediaPacket] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var packets: [BaichuanMediaPacket] = []
        while true {
            if buffer.count - cursor > Self.maxBuffer {
                let tail = buffer.suffix(3)
                buffer = Data(tail)
                cursor = 0
            }
            switch next() {
            case .packet(let packet, let consumed):
                cursor += consumed
                packets.append(packet)
                compactIfNeeded()
            case .consume(let consumed):
                cursor += consumed
                compactIfNeeded()
            case .needMore:
                compactIfNeeded()
                return packets
            case .skip:
                cursor += 1
            }
        }
    }

    // MARK: - Magics (little-endian, matching Neolink `bcmedia`)

    private enum Magic {
        static let infoV1: UInt32 = 0x3130_3031       // "1001"
        static let infoV2: UInt32 = 0x3230_3031       // "1002"
        static let iframeFirst: UInt32 = 0x6364_3030  // "00dc"
        static let iframeLast: UInt32 = 0x6364_3039   // "90dc"
        static let pframeFirst: UInt32 = 0x6364_3130  // "01dc"
        static let pframeLast: UInt32 = 0x6364_3139   // "91dc"
        static let aac: UInt32 = 0x6277_3530
        static let adpcm: UInt32 = 0x6277_3130
        static let adpcmData: UInt16 = 0x0100
    }

    private static let maxBuffer = 8_000_000
    private static let maxPayload = 6_000_000

    private enum Step {
        case packet(BaichuanMediaPacket, Int)
        /// Consume `bytes` without publishing. Used for audio, which has to
        /// stay aligned but is not played.
        case consume(Int)
        case needMore
        case skip
    }

    private mutating func next() -> Step {
        let available = buffer.count - cursor
        if available < 4 { return .needMore }
        let magic = u32(0)
        guard Self.isMediaMagic(magic) else { return .skip }
        switch magic {
        case Magic.infoV1, Magic.infoV2:
            return info()
        case Magic.iframeFirst...Magic.iframeLast:
            return frame(isKeyFrame: true)
        case Magic.pframeFirst...Magic.pframeLast:
            return frame(isKeyFrame: false)
        case Magic.aac:
            return audio(payloadIncludesSubheader: false)
        case Magic.adpcm:
            return audio(payloadIncludesSubheader: true)
        default:
            return .skip
        }
    }

    private func info() -> Step {
        // 4 byte magic + header size field + the fixed descriptor = 32 bytes.
        guard buffer.count - cursor >= 32 else { return .needMore }
        guard u32(4) == 32 else { return .skip }
        let width = Int(u32(8))
        let height = Int(u32(12))
        let fps = Int(u8(17))
        return .packet(.info(width: width, height: height, fps: fps), 32)
    }

    private func frame(isKeyFrame: Bool) -> Step {
        // magic + type + payload size + extra header size + microseconds + unknown
        guard buffer.count - cursor >= 24 else { return .needMore }
        guard let codec = codec(at: 4) else { return .skip }
        let payloadSize = Int(u32(8))
        let extra = Int(u32(12))
        if payloadSize < 0 || payloadSize > Self.maxPayload || extra < 0 || extra > Self.maxPayload {
            return .skip
        }
        let microseconds = u32(16)
        let pad = (8 - (payloadSize % 8)) % 8
        let total = 24 + extra + payloadSize + pad
        guard buffer.count - cursor >= total else { return .needMore }
        let payloadStart = cursor + 24 + extra
        let payload = buffer.subdata(in: payloadStart..<(payloadStart + payloadSize))
        let units = Self.nalUnits(annexB: payload)
        let video = BaichuanVideoFrame(
            codec: codec,
            nalUnits: units,
            isKeyFrame: isKeyFrame,
            microseconds: microseconds
        )
        return .packet(.video(video), total)
    }

    private func audio(payloadIncludesSubheader: Bool) -> Step {
        guard buffer.count - cursor >= 8 else { return .needMore }
        let payloadSize = Int(u16(4))
        if payloadSize > Self.maxPayload { return .skip }
        if payloadIncludesSubheader {
            guard payloadSize >= 4 else { return .skip }
            guard buffer.count - cursor >= 12 else { return .needMore }
            if u16(8) != Magic.adpcmData { return .skip }
        }
        let pad = (8 - (payloadSize % 8)) % 8
        let total = 8 + payloadSize + pad
        guard buffer.count - cursor >= total else { return .needMore }
        // Audio is not played. Consuming it keeps the next video frame aligned.
        return .consume(total)
    }

    private func codec(at offset: Int) -> BaichuanVideoFrame.Codec? {
        let base = cursor + offset
        guard buffer.count >= base + 4 else { return nil }
        let bytes = buffer.subdata(in: base..<(base + 4))
        switch String(data: bytes, encoding: .utf8) {
        case "H264": return .h264
        case "H265": return .h265
        default: return nil
        }
    }

    private func u32(_ offset: Int) -> UInt32 {
        buffer.readLE(at: cursor + offset, as: UInt32.self)
    }

    private func u16(_ offset: Int) -> UInt16 {
        buffer.readLE(at: cursor + offset, as: UInt16.self)
    }

    private func u8(_ offset: Int) -> UInt8 {
        buffer[buffer.startIndex + cursor + offset]
    }

    private mutating func compactIfNeeded() {
        guard cursor > 64 * 1024 else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }
}
