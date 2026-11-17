#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVDomain
import RVIsolation
import Synchronization
import Testing
@testable import RVMCP

@Suite("MCPSandbox proxies")
struct MCPSandboxProxyTests {
    static func proxy(credential: String = MCPSandbox.proxyCredential()) -> EgressProxy {
        EgressProxy(
            policy: EgressHostPolicy(allowedHosts: ["example.com"], relaysLoopback: false), record: { _ in },
            clientCredential: credential)
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

    /// Stopping one server's proxy leaves every other server's running: a
    /// test that cleans up its own server does not stop another test's.
    @Test func stoppingOneServersProxyLeavesAnothersRunning() throws {
        let mine = "proxy-mine-\(UUID().uuidString)"
        let theirs = "proxy-theirs-\(UUID().uuidString)"
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
        MCPSandbox.track(first, server: mine)
        MCPSandbox.track(second, server: theirs)
        MCPSandbox.stopProxies(server: mine)
        #expect(Self.accepts(firstPort) == false)
        #expect(Self.accepts(secondPort))
        #expect(MCPSandbox.proxies.withLock { $0.contains { $0.server == mine } } == false)
        #expect(MCPSandbox.proxies.withLock { $0.contains { $0.server == theirs } })
        MCPSandbox.stopProxies(server: theirs)
    }

    /// A plan that fails after a server's proxy started (here because a
    /// later server it names is not in mcp.json) stops that proxy and
    /// forgets it: nothing it planned runs, so nothing uses it.
    @Test func aPlanThatFailsStopsTheProxiesItStarted() throws {
        let server = "proxy-plan-\(UUID().uuidString)"
        let definition = MCPServerDefinition(
            name: server, command: "true", sandbox: MCPSandboxPolicy(network: false, hosts: ["example.com"]))
        let started = Mutex<(proxy: EgressProxy, port: Int)?>(nil)
        defer { started.withLock { $0?.proxy.stop() } }
        let planned = MCPLaunchPlanner.plan(
            servers: [server, "missing-\(server)"], configuration: MCPConfiguration(servers: [definition]),
            secrets: SecretsConfiguration(), resolver: SecretResolver { _ in .failure(.notFound("none")) },
            baseEnvironment: ["PATH": "/usr/bin:/bin"], requireSandbox: false,
            sandbox: { definition, launch, _ in
                // As `MCPSandbox.apply` plans a server with `sandbox.hosts`.
                let credential = MCPSandbox.proxyCredential()
                let proxy = Self.proxy(credential: credential)
                guard case .success(let port) = proxy.start() else { return .failure(.sandbox("no proxy")) }
                MCPSandbox.track(proxy, server: definition.name)
                started.withLock { $0 = (proxy, port) }
                var caged = launch
                caged.environment = MCPSandbox.proxyEnvironment(launch.environment, port: port, credential: credential)
                return .success(caged)
            })
        guard case .failure(.unknownServer) = planned else {
            Issue.record("expected the plan to fail: \(planned)")
            return
        }
        let port = try #require(started.withLock { $0?.port })
        #expect(Self.accepts(port) == false)
        #expect(MCPSandbox.proxies.withLock { $0.contains { $0.server == server } } == false)
    }
}
