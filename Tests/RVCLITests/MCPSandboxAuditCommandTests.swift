import Foundation
import RVHistory
import RVIsolation
import RVMCP
import RVPolicy
import Testing
@testable import RVCLI

/// The CLI half of `sandbox.enforcement: audit`: every pass-through is an
/// fsync'd `egress.observed` audit event (or the proxy denies), and the
/// owner sees which servers are in audit mode.
@Suite("rv mcp sandbox audit mode")
struct MCPSandboxAuditCommandTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-audit-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var config: URL { home.appendingPathComponent(".config/rv") }

        func environment() -> MCPEnvironment {
            MCPEnvironment(
                configDirectory: config, home: home, processEnvironment: [:], keychain: FakeKeychain().writer,
                approvalSigning: .file(configDirectory: config))
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func wouldBe(_ host: String) -> EgressProxyDenial {
        EgressProxyDenial(host: host, port: 443, reason: .deniedPolicy, recordedAt: Date())
    }

    private static func auditing(_ enforcement: MCPSandboxEnforcement) -> MCPConfiguration {
        MCPConfiguration(servers: [
            MCPServerDefinition(
                name: "gh", command: "gh-mcp",
                sandbox: MCPSandboxPolicy(network: false, hosts: ["api.github.com"], enforcement: enforcement))
        ])
    }

    @Test func everyPassThroughIsItsOwnObservedAuditEvent() throws {
        let fixture = Fixture()
        let record = DenialAudit.observed(configDirectory: fixture.config)
        #expect(record("gh", Self.wouldBe("uploads.example.com")))
        #expect(record("gh", Self.wouldBe("uploads.example.com")))
        let events = AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: ["egress.observed"]))
        #expect(events.count == 2)
        let event = events.first
        #expect(event?.kind == .egressObserved)
        #expect(event?.decision == .info)
        #expect(event?.subject == "uploads.example.com:443")
        #expect(event?.reason == "denied-policy")
        #expect(event?.detail["server"] == "gh")
        #expect(event?.detail["rule"] == "sandbox.hosts")
        #expect(event?.detail["would_be"] == "deny")
        #expect(event?.detail["because"] == "uploads.example.com is not in gh sandbox.hosts")
        #expect(AuditLedger(configDirectory: fixture.config).events(AuditFilter(kinds: ["egress"])).count == 2)
        let ocsf = try #require(event.map { AuditOCSF.object($0, hostName: "h") })
        #expect(ocsf["class_uid"] as? Int == 4001)
        #expect(ocsf["activity_id"] as? Int == 6)
        #expect(ocsf["disposition"] as? String == "Logged")
    }

    @Test func unwritableAuditLogReportsFailure() throws {
        let fixture = Fixture()
        try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: true)
        // The config directory is a regular file: the append cannot land.
        let blocked = fixture.home.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocked)
        #expect(DenialAudit.observed(configDirectory: blocked)("gh", Self.wouldBe("uploads.example.com")) == false)
    }

    @Test func listAndCheckNameEveryServerInAuditMode() throws {
        let fixture = Fixture()
        let environment = fixture.environment()
        let report = MCPRun.report(environment, project: nil, configuration: Self.auditing(.audit), rvExecutable: "")
        #expect(report.sandboxAudit == ["gh"])
        for text in [MCPRun.listText(report, home: fixture.home), MCPRun.checkText(report, home: fixture.home)] {
            #expect(text.contains("warning: gh sandbox.hosts is in audit mode"))
            #expect(text.contains("rv audit tail --kind egress.observed"))
        }
        let enforced = MCPRun.report(environment, project: nil, configuration: Self.auditing(.enforce), rvExecutable: "")
        #expect(enforced.sandboxAudit.isEmpty)
        #expect(MCPRun.listText(enforced, home: fixture.home).contains("audit mode") == false)
    }

    @Test func organizationPolicyKeepsAuditOffAndSaysSo() throws {
        let fixture = Fixture()
        var configuration = Self.auditing(.audit)
        configuration.managed = try ManagedPolicy.decode(Data(#"{"version": 1}"#.utf8)).get()
        let report = MCPRun.report(fixture.environment(), project: nil, configuration: configuration, rvExecutable: "")
        #expect(report.sandboxAudit.isEmpty)
        #expect(report.sandboxAuditIgnored == ["gh"])
        #expect(MCPRun.listText(report, home: fixture.home).contains("sandbox.hosts is enforced"))
    }

    @Test func trustReviewShowsAuditMode() {
        let configuration = Self.auditing(.audit)
        let review = MCPRun.trustReview(configuration)
        #expect(review.contains("    sandbox enforcement audit"))
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, review))
        let without = review.replacingOccurrences(of: "    sandbox enforcement audit", with: "")
        #expect(MCPRun.trustReviewShowsEveryLiteral(configuration, without) == false)
    }
}
