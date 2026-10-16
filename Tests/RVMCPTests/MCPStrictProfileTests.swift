#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RVIsolation
import Testing
@testable import RVMCP

@Suite("MCP strict profile and sandbox hosts")
struct MCPStrictProfileTests {
    private static let strict = #"""
        {"version": 1, "profile": "strict", "defaultDecision": "allow", "servers": [
          {"name": "gh", "command": "gh-mcp", "sandbox": {"hosts": ["api.github.com", "Uploads.GitHub.com"]},
           "tools": {"default": "allow", "allow": ["get_*"], "ask": ["create_*"]}},
          {"name": "linear", "url": "https://mcp.linear.app/mcp"}
        ]}
        """#

    @Test func strictProfileAndHostsRoundTripAndUnlistedToolsDeny() throws {
        let configuration = try MCPConfiguration.decode(Data(Self.strict.utf8)).get()
        #expect(configuration.profile == .strict)
        let gh = try #require(configuration.server(named: "gh"))
        #expect(gh.sandbox == MCPSandboxPolicy(network: false, hosts: ["api.github.com", "uploads.github.com"]))
        #expect(configuration.decision(server: gh, tool: "get_issue") == .allow)
        #expect(configuration.decision(server: gh, tool: "create_issue") == .ask)
        #expect(configuration.decision(server: gh, tool: "delete_repo") == .deny)
        let linear = try #require(configuration.server(named: "linear"))
        #expect(configuration.decision(server: linear, tool: "anything") == .deny)

        let encoded = configuration.encoded().prettyText
        #expect(encoded.contains(#""profile" : "strict""#) || encoded.contains(#""profile": "strict""#))
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get() == configuration)

        var standard = configuration
        standard.profile = .standard
        #expect(standard.decision(server: gh, tool: "delete_repo") == .allow)
        #expect(standard.encoded().prettyText.contains("profile") == false)
    }

    @Test func refusesBadProfilesAndHosts() {
        func problem(_ top: String = "", sandbox: String) -> String? {
            let text = #"{"version": 1\#(top), "servers": [{"name": "s", "command": "x", "sandbox": \#(sandbox)}]}"#
            guard case .failure(let error) = MCPConfiguration.decode(Data(text.utf8)) else { return nil }
            return error.message
        }
        #expect(problem(#", "profile": "lax""#, sandbox: "{}")?.contains(#"profile must be "standard" or "strict""#) == true)
        #expect(problem(sandbox: #"{"hosts": ["https://api.github.com"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["10.0.0.1"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["localhost"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": ["*.github.com"]}"#)?.contains("not a host name") == true)
        #expect(problem(sandbox: #"{"hosts": "api.github.com"}"#)?.contains("sandbox.hosts must be") == true)
        #expect(problem(sandbox: #"{"hosts": ["api.github.com"], "network": true}"#)?.contains("drop network: true") == true)
        let many = (0...MCPSandboxPolicy.maximumHosts).map { "\"h\($0).example.com\"" }.joined(separator: ",")
        #expect(problem(sandbox: #"{"hosts": [\#(many)]}"#)?.contains("more than \(MCPSandboxPolicy.maximumHosts)") == true)
    }

    @Test func plannerHoldsStrictServersToASandboxWithoutOpenNetwork() throws {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "bare", command: "b"),
            MCPServerDefinition(name: "open", command: "o", sandbox: MCPSandboxPolicy(network: true)),
            MCPServerDefinition(name: "closed", command: "c", sandbox: MCPSandboxPolicy(network: false)),
            MCPServerDefinition(name: "proxied", command: "p", sandbox: MCPSandboxPolicy(network: false, hosts: ["api.example.com"])),
            MCPServerDefinition(name: "remote", remote: MCPRemoteServer(url: try #require(URL(string: "https://mcp.example.com/mcp")))),
        ])
        configuration.profile = .strict
        func plan(_ name: String) -> Result<Void, MCPLaunchError> {
            MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: SecretsConfiguration(),
                resolver: SecretResolver { _ in .failure(.notFound("none")) }, baseEnvironment: [:]
            ).map { _ in () }
        }
        guard case .failure(let bare) = plan("bare"), case .failure(let open) = plan("open") else {
            Issue.record("strict profile launched an uncaged or open-network server")
            return
        }
        #expect(bare.message == #"sandbox: profile strict requires a sandbox for bare; add "sandbox" to its mcp.json entry"#)
        #expect(open.message == "sandbox: profile strict keeps open off the network; list the hosts it needs in sandbox.hosts")
        for name in ["closed", "proxied", "remote"] {
            #expect((try? plan(name).get()) != nil, "\(name)")
        }
        configuration.profile = .standard
        #expect((try? plan("bare").get()) != nil)
    }

    @Test func profileTextLetsTheCageReachOnlyItsProxy() {
        let policy = MCPSandboxPolicy(network: false, hosts: ["api.example.com"])
        let proxied = try! MCPSandbox.profile(
            policy: policy, scratch: "/s", home: "/h", configDirectory: "/h/.config/rv", temporaryDirectory: "/t", proxyPort: 4321).get()
        #expect(proxied.contains("(deny network*)\n(allow network-outbound (remote tcp \"localhost:4321\"))"))
        // The proxy port is the only localhost reach the profile grants.
        #expect(proxied.components(separatedBy: "localhost:").count == 2)
        let closed = try! MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: "/s", home: "/h", configDirectory: "/h/.config/rv",
            temporaryDirectory: "/t").get()
        #expect(closed.contains("(deny network*)") && closed.contains("network-outbound") == false)
    }

    @Test func proxyEnvironmentPointsEveryClientAtTheProxy() {
        let environment = MCPSandbox.proxyEnvironment(
            ["NO_PROXY": "*", "no_proxy": "*", "PATH": "/bin"], port: 4321, credential: "abc")
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            #expect(environment[key] == "http://abc@127.0.0.1:4321", "\(key)")
        }
        #expect(environment["NODE_USE_ENV_PROXY"] == "1")
        #expect(environment["NO_PROXY"] == nil && environment["no_proxy"] == nil)
        #expect(environment["PATH"] == "/bin")
    }
}

#if os(macOS)
@Suite("MCPSandbox hosts (live sandbox-exec)")
struct MCPSandboxHostsLiveTests {
    /// A listening socket on 127.0.0.1:0. Copyable, unlike the OAuth redirect listener.
    final class Loopback: @unchecked Sendable {
        let fd: Int32
        let port: Int

        init?() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            self.fd = fd
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard bound == 0, listen(fd, 1) == 0, named == 0 else {
                close(fd)
                return nil
            }
            port = Int(UInt16(bigEndian: actual.sin_port))
        }

        deinit { close(fd) }
    }

    @Test func cagedServerReachesItsProxyButNothingElse() throws {
        // Under the real home directory, never the checkout: a checkout
        // under /tmp sits inside the cage's writable temp roots by design.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rv-cage-test-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/rv")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let other = try #require(Loopback())
        let script = """
            nc -z -G 2 127.0.0.1 \(other.port) && echo DIRECT_OK
            nc -z -G 2 127.0.0.1 "${HTTPS_PROXY##*:}" && echo PROXY_OK
            /usr/bin/python3 -c 'import socket; socket.getaddrinfo("www.apple.com", 443)' 2>/dev/null && echo DNS_OK
            echo "proxy=$HTTPS_PROXY"
            """
        var definition = MCPServerDefinition(name: "proxied", command: "/bin/sh", args: ["-c", script])
        definition.sandbox = MCPSandboxPolicy(network: false, hosts: ["api.example.com"])
        let launch = MCPUpstreamLaunch(
            server: "proxied", executable: "/usr/bin/env", arguments: ["/bin/sh", "-c", script], environment: ["PATH": "/usr/bin:/bin"])
        let caged = try MCPSandbox.apply(configDirectory: config, home: home)(definition, launch).get()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: caged.executable)
        process.arguments = caged.arguments
        process.environment = caged.environment
        if let directory = caged.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(output.contains("proxy=http://") && output.contains("@127.0.0.1:"), "\(output)")
        #expect(output.contains("PROXY_OK"), "\(output)")
        #expect(output.contains("DIRECT_OK") == false, "\(output)")
        #expect(output.contains("DNS_OK") == false, "\(output)")
    }
}
#endif
