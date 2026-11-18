#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
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
                approvalSigning: .file(configDirectory: config),
                presence: UserPresence { _, _ in .confirmed(method: "test") })
        }

        /// mcp.json as an outside edit: owner-only, unsigned.
        func writeMCP(_ sandbox: String) throws {
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let url = config.appendingPathComponent("mcp.json")
            try Data(#"{"version":1,"servers":[{"name":"gh","command":"gh-mcp","sandbox":\#(sandbox)}]}"#.utf8).write(to: url)
            chmod(url.path, 0o600)
            chmod(config.path, 0o700)
        }

        func changes() -> [AuditEvent] {
            AuditLedger(configDirectory: config).events(AuditFilter(kinds: ["config.changed"]))
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

    @Test func trustingAuditModeRecordsALoosening() async throws {
        let fixture = Fixture()
        try fixture.writeMCP(#"{"hosts":["api.github.com"],"enforcement":"audit"}"#)
        _ = try await MCPRun.trust(environment: fixture.environment(), show: { _ in }).get()
        #expect(fixture.environment().integrity == .trusted)
        let change = try #require(fixture.changes().first)
        #expect(fixture.changes().count == 1)
        #expect(change.subject == "mcp.sandbox.enforcement")
        #expect(change.detail["new"] == "audit")
        #expect(change.detail["servers"] == "gh")
        #expect(change.detail["direction"] == "loosening")
        #expect(change.detail["authorized_by"] == "owner (test)")
    }

    @Test func trustingEnforceRecordsNoSandboxChange() async throws {
        let fixture = Fixture()
        try fixture.writeMCP(#"{"hosts":["api.github.com"]}"#)
        _ = try await MCPRun.trust(environment: fixture.environment(), show: { _ in }).get()
        #expect(fixture.environment().integrity == .trusted)
        #expect(fixture.changes().isEmpty)
    }

    @Test func unrecordableAuditModeIsNotTrusted() async throws {
        let fixture = Fixture()
        try fixture.writeMCP(#"{"hosts":["api.github.com"],"enforcement":"audit"}"#)
        // audit.jsonl is a directory: no append can land.
        try FileManager.default.createDirectory(
            at: AuditLog.fileURL(configDirectory: fixture.config), withIntermediateDirectories: true)
        let result = await ConfigChangeAudit.$lockTimeout.withValue(.milliseconds(100)) {
            await MCPRun.trust(environment: fixture.environment(), show: { _ in })
        }
        guard case .failure(let failure) = result else {
            Issue.record("an unrecordable audit mode was trusted")
            return
        }
        #expect(failure.exitCode == ConfigChangeRefusal.exitCode)
        #expect(failure.message.contains("the audit log could not record the mcp.sandbox.enforcement change"))
        #expect(fixture.environment().integrity.isTrusted == false)
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
