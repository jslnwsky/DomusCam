import Foundation
import Network

/// One-shot TCP connect used to decide whether a port is worth talking to.
///
/// A closed or silent port used to become a `URLSession` task that sat until
/// `NSURLErrorTimedOut`. Checking the socket first means those tasks are never
/// created. A refused connection finishes immediately; a host that drops the
/// SYN is bounded by `timeout`.
public enum TCPPortProbe {

    /// `true` only when a TCP handshake to `host:port` completes.
    /// Never throws, and does not log the host (AGENTS.md §11).
    public static func isAccepting(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 0.4
    ) async -> Bool {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let box = ProbeOnce(continuation)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.75-c.DomusCam.tcp-port-probe")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    box.finish(true)
                case .failed:
                    connection.cancel()
                    box.finish(false)
                case .waiting(let error):
                    if Self.isDefinitiveRefusal(error) {
                        connection.cancel()
                        box.finish(false)
                    }
                case .cancelled:
                    box.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                box.finish(false)
            }
        }
    }

    /// POSIX refusals and unreachable hosts will not become a successful
    /// handshake. A silent drop stays in `.waiting` until the deadline.
    static func isDefinitiveRefusal(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        switch code {
        case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EADDRNOTAVAIL:
            return true
        default:
            return false
        }
    }

    private final class ProbeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }
        func finish(_ value: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}
