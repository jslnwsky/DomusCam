import Testing
import Network
@testable import ReolinkAPI

@Suite("TCP port probe")
struct TCPPortProbeTests {

    @Test func refusedAndUnreachablePortsAreClosed() {
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ECONNREFUSED)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.EHOSTUNREACH)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ENETUNREACH)))
        #expect(TCPPortProbe.isDefinitiveRefusal(NWError.posix(.EADDRNOTAVAIL)))
    }

    @Test func aTimeoutIsNotARefusal() {
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ETIMEDOUT)))
        #expect(!TCPPortProbe.isDefinitiveRefusal(NWError.posix(.ECONNRESET)))
    }
}
