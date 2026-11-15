#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import Testing
@testable import RVMCP

@Suite("MCPSandbox proxies")
struct MCPSandboxProxyTests {
    static func proxy() -> EgressProxy {
        EgressProxy(
            policy: EgressHostPolicy(allowedHosts: ["example.com"], relaysLoopback: false), record: { _ in },
            clientCredential: MCPSandbox.proxyCredential())
    }

    /// Whether something accepts a TCP connection on loopback `port`.
    static func accepts(_ port: Int) -> Bool {
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// A server planned again (a restart) gets a new proxy; the one its
    /// last launch used is stopped, not kept for the rest of serve.
    @Test func aServerPlannedAgainStopsItsEarlierProxy() throws {
        let server = "proxy-test-\(UUID().uuidString)"
        let first = Self.proxy()
        let second = Self.proxy()
        guard case .success(let firstPort) = first.start(), case .success(let secondPort) = second.start() else {
            Issue.record("a proxy did not start")
            return
        }
        defer {
            first.stop()
            second.stop()
        }
        MCPSandbox.track(first, server: server)
        #expect(Self.accepts(firstPort))
        MCPSandbox.track(second, server: server)
        #expect(Self.accepts(firstPort) == false)
        #expect(Self.accepts(secondPort))
        #expect(MCPSandbox.proxies.withLock { $0.filter { $0.server == server }.count } <= 1)
    }
}
