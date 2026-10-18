import Foundation

/// One encoded access unit handed to `LiveVideoPlayer` by a non-RTSP source.
///
/// NAL units are raw (no Annex-B start code), which is the shape
/// `H264SampleBufferAssembler` and `H265SampleBufferAssembler` already take
/// from the RTP depacketizer. `timestamp` is a 90 kHz clock; it only has to
/// change between frames.
public struct LiveEncodedFrame: Sendable {
    public enum Codec: Sendable, Equatable {
        case h264
        case h265
    }

    public let codec: Codec
    public let nalUnits: [Data]
    public let timestamp: UInt32

    public init(codec: Codec, nalUnits: [Data], timestamp: UInt32) {
        self.codec = codec
        self.nalUnits = nalUnits
        self.timestamp = timestamp
    }
}

/// Whether a live tile should open RTSP, open a Baichuan preview, or stop.
/// A closed RTSP port must not walk the six candidate URLs.
public enum LiveVideoRoute: Sendable, Equatable {
    case rtsp
    case baichuan
    case rtspOff

    public static func choose(usingBaichuanControl: Bool, rtspPortOpen: Bool) -> LiveVideoRoute {
        if rtspPortOpen { return .rtsp }
        if usingBaichuanControl { return .baichuan }
        return .rtspOff
    }
}

/// Shown on the tile when port 554 does not accept a connection.
/// No host, URL, or password — the tile adds the Enable RTSP action.
public enum RTSPStartDecision {
    public static let offMessage = "RTSP is off on this camera"
    public static func shouldTryCandidates(portOpen: Bool) -> Bool { portOpen }
}
