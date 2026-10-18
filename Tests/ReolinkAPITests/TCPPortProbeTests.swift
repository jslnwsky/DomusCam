import Testing
import Foundation
import Darwin
import Network
@testable import ReolinkAPI

/// Loopback only. Nothing here dials a camera or leaves the machine:
/// an open port is a socket listening on 127.0.0.1, a closed port is a
/// socket bound there without `listen`, and the remaining cases fail
/// inside the probe before a handshake.
@Suite("TCP port probe")
struct TCPPortProbeTests {

    @Test func refusedAndUnreachablePortsAreClosed() {
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ECONNREFUSED)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.EHOSTUNREACH)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ENETUNREACH)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.EADDRNOTAVAIL)))
    }

    @Test func aTimeoutOrNonPosixErrorIsNotARefusal() {
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ETIMEDOUT)))
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ECONNRESET)))
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.posix(.EHOSTDOWN)))
        // DNS and TLS failures are not "the port is closed". The probe
        // keeps waiting for those until its own deadline.
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.dns(DNSServiceErrorType(-65563))))
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.tls(OSStatus(-9806))))
    }

    @Test func anEmptyHostOrPortZeroNeverConnects() async {
        let empty = await TCPPortProbe.isAccepting(host: "", port: 80, timeout: 0.2)
        #expect(!empty)
        let portZero = await TCPPortProbe.isAccepting(host: "127.0.0.1", port: 0, timeout: 0.2)
        #expect(!portZero)
    }

    @Test func anInvalidAddressFailsClosed() async {
        let open = await TCPPortProbe.isAccepting(host: "256.256.256.256", port: 9, timeout: 0.5)
        #expect(!open)
    }

    @Test func aListeningLoopbackPortAccepts() async throws {
        let socket = try LoopbackSocket.open(listening: true)
        defer { socket.closeSocket() }
        socket.acceptOne()
        let open = await TCPPortProbe.isAccepting(host: "127.0.0.1", port: socket.port, timeout: 2)
        #expect(open)
    }

    @Test func aBoundButUnlisteningPortIsClosed() async throws {
        let socket = try LoopbackSocket.open(listening: false)
        defer { socket.closeSocket() }
        // Short deadline so the probe's timer closure runs before this
        // test returns. The refusal finishes first; the timer still has
        // to cancel the socket and record "closed".
        let closed = await TCPPortProbe.isAccepting(host: "127.0.0.1", port: socket.port, timeout: 0.05)
        #expect(!closed)
        try await Task.sleep(for: .milliseconds(150))
    }
}

/// A TCP socket bound to 127.0.0.1 on an ephemeral port.
private struct LoopbackSocket {
    let fd: Int32
    let port: UInt16

    static func open(listening: Bool) throws -> LoopbackSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        if listening {
            guard Darwin.listen(fd, 8) == 0 else {
                Darwin.close(fd)
                throw URLError(.cannotConnectToHost)
            }
        }
        var got = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        // `sin_port` is network byte order.
        return LoopbackSocket(fd: fd, port: UInt16(bigEndian: got.sin_port))
    }

    func acceptOne() {
        let fd = self.fd
        DispatchQueue.global().async {
            var storage = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &length)
                }
            }
            if client >= 0 { Darwin.close(client) }
        }
    }

    func closeSocket() {
        Darwin.close(fd)
    }
}
