import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVMCP

/// `sandbox.enforcement`: the owner can trial a `sandbox.hosts` list in
/// audit mode. Only an exact "enforce" or "audit" parses; audit holds only
/// in a trusted mcp.json with no organization policy.
@Suite("MCP sandbox audit mode")
struct MCPSandboxAuditTests {
    private static func file(_ sandbox: String) -> Data {
        Data(#"{"version": 1, "servers": [{"name": "gh", "command": "gh-mcp", "sandbox": \#(sandbox)}]}"#.utf8)
    }

    private static func problem(_ sandbox: String) -> String? {
        guard case .failure(let error) = MCPConfiguration.decode(file(sandbox)) else { return nil }
        return error.message
    }

    @Test func auditParsesAndRoundTrips() throws {
        let configuration = try MCPConfiguration.decode(Self.file(#"{"hosts": ["api.github.com"], "enforcement": "audit"}"#)).get()
        let gh = try #require(configuration.server(named: "gh"))
        #expect(gh.sandbox?.enforcement == .audit)
        let encoded = configuration.encoded().prettyText
        #expect(encoded.contains("audit"))
        #expect(try MCPConfiguration.decode(Data(encoded.utf8)).get() == configuration)
    }

    @Test func enforceIsTheDefaultAndIsNotWritten() throws {
        for sandbox in [#"{"hosts": ["api.github.com"]}"#, #"{"hosts": ["api.github.com"], "enforcement": "enforce"}"#] {
            let configuration = try MCPConfiguration.decode(Self.file(sandbox)).get()
            #expect(configuration.server(named: "gh")?.sandbox?.enforcement == .enforce)
            #expect(configuration.encoded().prettyText.contains("enforcement") == false)
        }
    }

    @Test func unknownOrAmbiguousEnforcementIsInvalid() {
        for value in [#""Audit""#, #""dry-run""#, #""""#, "true", "1", "null", #"["audit"]"#] {
            let message = Self.problem(#"{"hosts": ["api.github.com"], "enforcement": \#(value)}"#)
            #expect(message?.contains(#"sandbox.enforcement must be "enforce" or "audit""#) == true, "\(value)")
        }
        // Nothing to audit without a host list.
        #expect(Self.problem(#"{"enforcement": "audit"}"#)?.contains("needs sandbox.hosts") == true)
        #expect(Self.problem(#"{"network": false, "enforcement": "audit"}"#)?.contains("needs sandbox.hosts") == true)
    }

    @Test func auditHoldsOnlyInATrustedFileWithoutOrganizationPolicy() throws {
        var configuration = try MCPConfiguration.decode(Self.file(#"{"hosts": ["api.github.com"], "enforcement": "audit"}"#)).get()
        let gh = try #require(configuration.server(named: "gh"))
        #expect(configuration.sandboxEnforcement(for: gh) == .audit)

        configuration.untrusted = true
        #expect(configuration.sandboxEnforcement(for: gh) == .enforce)

        configuration.untrusted = false
        configuration.managed = try ManagedPolicy.decode(Data(#"{"version": 1}"#.utf8)).get()
        #expect(configuration.sandboxEnforcement(for: gh) == .enforce)

        let enforced = try MCPConfiguration.decode(Self.file(#"{"hosts": ["api.github.com"]}"#)).get()
        #expect(enforced.sandboxEnforcement(for: try #require(enforced.server(named: "gh"))) == .enforce)
    }

    @Test func hostsProxyAuditsOnlyWhenEnforcementIsAudit() {
        let audited = MCPSandbox.hostsProxy(
            server: "gh", hosts: ["api.github.com"], enforcement: .audit, credential: "c",
            denied: { _, _ in }, audited: { _, _ in true })
        let enforced = MCPSandbox.hostsProxy(
            server: "gh", hosts: ["api.github.com"], enforcement: .enforce, credential: "c",
            denied: { _, _ in }, audited: { _, _ in true })
        #expect(audited.auditsAllowlist)
        #expect(enforced.auditsAllowlist == false)
    }
}
