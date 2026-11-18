import Foundation
import RVDomain
import Testing
@testable import RVMCP

/// `sandbox.allowed_ips` in mcp.json: the owner-set private networks a
/// listed host may reach. Any bad entry refuses the whole file.
@Suite("MCP sandbox allowed_ips")
struct MCPSandboxAllowedIPsTests {
    static func document(sandbox: String) -> String {
        #"{"version": 1, "servers": [{"name": "staging", "command": "staging-mcp", "sandbox": \#(sandbox)}]}"#
    }

    static func decode(sandbox: String) -> Result<MCPConfiguration, MCPConfigurationError> {
        MCPConfiguration.decode(Data(document(sandbox: sandbox).utf8))
    }

    static func problem(sandbox: String) -> String? {
        guard case .failure(let error) = decode(sandbox: sandbox) else { return nil }
        return error.message
    }

    @Test func decodesAndRoundTripsPerHostRanges() throws {
        let configuration = try Self.decode(sandbox: #"""
            {"hosts": ["Staging.Corp.Lan", "api.example.com"],
             "allowed_ips": {"STAGING.corp.lan": ["10.0.5.0/24", "fd12:3456:789a::/48", "::ffff:10.0.5.0/120"]}}
            """#).get()
        let sandbox = try #require(configuration.server(named: "staging")?.sandbox)
        #expect(sandbox.hosts == ["staging.corp.lan", "api.example.com"])
        #expect(sandbox.allowedIPs.keys.sorted() == ["staging.corp.lan"])
        #expect(sandbox.allowedIPs["staging.corp.lan"]?.entries == ["10.0.5.0/24", "fd12:3456:789a::/48"])

        let encoded = configuration.encoded().prettyText
        #expect(encoded.contains("allowed_ips"))
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get() == configuration)
    }

    /// Fail closed: one malformed, scoped, host-bit, or forbidden entry
    /// refuses the configuration rather than dropping that entry.
    @Test(arguments: [
        (#"["10.0.5.0/33"]"#, "is not an IP address or CIDR network"),
        (#"["10.0.5.0/24", "nonsense"]"#, "nonsense is not an IP address"),
        (#"["10.0.5.20/24"]"#, "host bits set"),
        (#"["fd12::1%en0"]"#, "zone or scope"),
        (#"["169.254.169.254"]"#, "link-local and cloud metadata"),
        (#"["127.0.0.1/32"]"#, "loopback"),
        (#"["fd00:ec2::254"]"#, "cloud metadata"),
        (#"["10.0.0.0/8", "0.0.0.0/0"]"#, "never relays"),
        (#"["::ffff:169.254.169.254"]"#, "link-local and cloud metadata"),
        (#"[]"#, "at least one"),
        (#""10.0.5.0/24""#, "must be an array"),
        (#"[10]"#, "must be an array"),
    ])
    func refusesBadRanges(_ entry: (String, String)) throws {
        let message = try #require(Self.problem(sandbox: #"{"hosts": ["staging.corp.lan"], "allowed_ips": {"staging.corp.lan": \#(entry.0)}}"#))
        #expect(message.contains(entry.1), "\(message)")
        #expect(message.contains("sandbox.allowed_ips.staging.corp.lan"), "\(message)")
    }

    @Test func refusesRangesForHostsTheSandboxDoesNotList() throws {
        let unlisted = try #require(Self.problem(sandbox: #"{"hosts": ["api.example.com"], "allowed_ips": {"db.corp.lan": ["10.0.5.0/24"]}}"#))
        #expect(unlisted.contains("db.corp.lan is not in sandbox.hosts"))
        let noHosts = try #require(Self.problem(sandbox: #"{"network": false, "allowed_ips": {"db.corp.lan": ["10.0.5.0/24"]}}"#))
        #expect(noHosts.contains("is not in sandbox.hosts"))
        let shape = try #require(Self.problem(sandbox: #"{"hosts": ["db.corp.lan"], "allowed_ips": ["10.0.5.0/24"]}"#))
        #expect(shape.contains("must map a host"))
        let twice = try #require(Self.problem(
            sandbox: #"{"hosts": ["db.corp.lan"], "allowed_ips": {"db.corp.lan": ["10.0.5.0/24"], "DB.corp.lan": ["10.0.6.0/24"]}}"#))
        #expect(twice.contains("names db.corp.lan twice"))
    }

    @Test func sandboxWithoutRangesIsUnchanged() throws {
        let configuration = try Self.decode(sandbox: #"{"hosts": ["api.example.com"]}"#).get()
        let sandbox = try #require(configuration.server(named: "staging")?.sandbox)
        #expect(sandbox == MCPSandboxPolicy(network: false, hosts: ["api.example.com"]))
        #expect(configuration.encoded().prettyText.contains("allowed_ips") == false)
    }
}
