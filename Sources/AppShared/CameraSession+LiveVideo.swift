import Foundation
import OSLog
import ReolinkAPI
import ReolinkBaichuan
import ReolinkStreaming

private let log = Logger(subsystem: "com.75-c.DomusCam.app", category: "session")

extension CameraSession {

    /// Live H.264/H.265 from the Baichuan session this camera is already
    /// logged in on. Nil when that session is gone or the camera rejects
    /// Preview — the caller then shows the RTSP-off state instead of
    /// opening port 554 six times.
    public func baichuanLiveFrames(channel: Int, stream: StreamKind) async -> AsyncStream<LiveEncodedFrame>? {
        guard let client = baichuanClient else { return nil }
        let channelID = UInt8(clamping: channel)
        do {
            let frames = try await client.liveVideoFrames(channel: channelID, stream: stream)
            return AsyncStream { continuation in
                let task = Task {
                    for await frame in frames {
                        let codec: LiveEncodedFrame.Codec = frame.codec == .h265 ? .h265 : .h264
                        continuation.yield(LiveEncodedFrame(
                            codec: codec,
                            nalUnits: frame.nalUnits,
                            timestamp: frame.rtpTimestamp
                        ))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        } catch {
            log.warning("Baichuan live preview did not start")
            return nil
        }
    }

    /// Turn on the camera's RTSP service over the Baichuan control connection.
    /// Asks the camera only; the web API stays off. Waits briefly so the
    /// following port check can see 554 come up.
    public func enableRTSP() async throws {
        guard let client = baichuanClient else { throw BaichuanError.notLoggedIn }
        try await client.setRTSPEnabled(true)
        try? await Task.sleep(for: .seconds(1))
    }
}
