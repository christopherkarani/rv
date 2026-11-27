#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import RVIsolation
import RVMCP
import RVPolicy
import Testing
@testable import RVCLI

/// `rv mcp list` and `check` never call a server governed when
/// `rv mcp serve` would refuse to start it.
@Suite("rv mcp list says off when serve would refuse")
struct MCPListOffTests {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-off-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var config: URL { home.appendingPathComponent(".config/rv") }
        var rv: URL { home.appendingPathComponent("bin/rv") }
        var mcpJSON: URL { config.appendingPathComponent("mcp.json") }

        init() throws {
            try write(".config/rv/mcp.json", #"{"version":1,"servers":[{"name":"wax","url":"https://mcp.example/mcp"}]}"#)
            chmod(mcpJSON.path, 0o600)
            chmod(config.path, 0o700)
            try write("bin/rv", "")
            try write(".cursor/mcp.json", """
                {"mcpServers": {"wax": {"command": "\(rv.path)", "args": ["mcp", "serve", "--server", "wax"]}}}
                """)
        }

        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        /// A key held apart from the user's processes, as the custodian holds it.
        var custodianSigning: MCPApprovalSigning {
            let backing = MCPApprovalSigning.file(configDirectory: config)
            return MCPApprovalSigning(
                honorsGrants: true, status: backing.status, mac: backing.mac, verify: backing.verify)
        }

        func environment(_ signing: MCPApprovalSigning) -> MCPEnvironment {
            MCPEnvironment(
                configDirectory: config, home: home, processEnvironment: [:], keychain: FakeKeychain().writer,
                approvalSigning: signing, oauthTokens: .file(configDirectory: config))
        }

        func report(_ signing: MCPApprovalSigning) throws -> MCPRun.Report {
            let environment = environment(signing)
            let configuration = try MCPRun.configuration(environment).get()
            return MCPRun.report(environment, project: nil, configuration: configuration, rvExecutable: rv.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aTrustedServerIsGovernedAndAnUntrustedOneIsOffWithItsFix() throws {
        let fixture = try Fixture()
        let signing = fixture.custodianSigning
        #expect(MCPIntegrity.signCurrent(configDirectory: fixture.config, signing: signing))
        let trusted = try fixture.report(signing)
        let row = try #require(trusted.rows.first { $0.name == "wax" })
        #expect(row.status == "governed")
        #expect(row.offReason == nil)
        #expect(MCPRun.nextLines(trusted).isEmpty)

        // Edited outside rv: serve refuses it, so list must not say governed.
        try fixture.write(".config/rv/mcp.json", #"{"version":1,"servers":[{"name":"wax","url":"https://mcp.example/mcp"}]} "#)
        chmod(fixture.mcpJSON.path, 0o600)
        let edited = try fixture.report(signing)
        let off = try #require(edited.rows.first { $0.name == "wax" })
        #expect(off.status == "off")
        #expect(off.offReason == "off · mcp.json is untrusted")
        #expect(off.next == "rv mcp trust")
        let list = MCPRun.listText(edited, home: fixture.home)
        #expect(list.contains("governed") == false)
        #expect(list.contains("✕ off · mcp.json is untrusted"))
        #expect(list.contains("1 host entry in 1 file: 1 off"))
        let lines = list.split(separator: "\n")
        #expect(lines.last == "→ rv mcp trust")

        #expect(edited.passes == false)
        let check = MCPRun.checkText(edited, home: fixture.home)
        #expect(check.contains("off  wax  cursor"))
        #expect(check.contains("off  wax  cursor ~/.cursor/mcp.json\n  ✕ off · mcp.json is untrusted\n"))
        #expect(check.split(separator: "\n").last == "→ rv mcp trust")
    }

    @Test func withoutAKeyCustodianNothingIsGoverned() throws {
        let fixture = try Fixture()
        // Linux without the custodian: the key is a file any process of the user can read.
        let report = try fixture.report(.file(configDirectory: fixture.config, honorsGrants: false))
        let row = try #require(report.rows.first { $0.name == "wax" })
        #expect(row.status == "off")
        #expect(row.offReason == "off · mcp.json can't be trusted without a key custodian")
        #expect(MCPRun.nextLines(report) == ["→ sudo rv mcp custodian install"])
    }

    @Test func anOffRowsFixIsTheLastLineNotAFixLine() {
        #expect(MCPRun.fixLine(status: .off, row: MCPRun.Row(
            host: "cursor", scope: "user", configPath: "/x", name: "wax", status: "off", command: "rv",
            environmentNames: [], headerNames: [], plaintextCredentials: [], governedServer: "wax",
            offReason: "off · mcp.json is untrusted", next: "rv mcp trust")) == nil)
    }

    /// Serve refuses a server whose secret secrets.json does not define;
    /// list says so without resolving anything.
    @Test func anUndefinedSecretIsOffWithItsFix() throws {
        let fixture = try Fixture()
        try fixture.write(".config/rv/mcp.json", #"""
            {"version":1,"servers":[{"name":"wax","url":"https://mcp.example/mcp","headers":{"Authorization":"Bearer ${secret:WAX_TOKEN}"}}]}
            """#)
        chmod(fixture.mcpJSON.path, 0o600)
        let signing = fixture.custodianSigning
        #expect(MCPIntegrity.signCurrent(configDirectory: fixture.config, signing: signing))
        let report = try fixture.report(signing)
        let row = try #require(report.rows.first { $0.name == "wax" })
        #expect(row.status == "off")
        #expect(row.offReason == "off · secret WAX_TOKEN is not set up")
        #expect(MCPRun.nextLines(report) == ["→ rv secrets set WAX_TOKEN"])
    }

    /// What `rv mcp serve --server wax` answers the host with, from the
    /// same plan it would launch from.
    @Test func serveRefusesWithTheCauseTheAgentHears() throws {
        let fixture = try Fixture()
        let unsigned = fixture.environment(fixture.custodianSigning)
        let configuration = try MCPRun.configuration(unsigned).get()
        let plan = MCPRun.upstreamPlan(
            names: ["wax"], configuration: configuration, environment: unsigned, secrets: SecretsConfiguration(),
            resolver: SecretResolver { _ in .failure(.notFound("none")) })
        guard case .failure(let refusal) = plan else {
            Issue.record("an unsigned mcp.json must not plan a launch")
            return
        }
        #expect(refusal.cause == .untrusted)
        #expect(refusal.log.hasSuffix("not launching MCP servers"))
        #expect(refusal.agentMessage == "✕ wax is off · mcp.json is untrusted · nothing ran\n→ ask your user: rv mcp trust")

        let sameUser = fixture.environment(.file(configDirectory: fixture.config, honorsGrants: false))
        guard case .failure(let custodian) = MCPRun.upstreamPlan(
            names: ["wax"], configuration: try MCPRun.configuration(sameUser).get(), environment: sameUser,
            secrets: SecretsConfiguration(), resolver: SecretResolver { _ in .failure(.notFound("none")) })
        else {
            Issue.record("no custodian: nothing launches")
            return
        }
        #expect(custodian.cause == .trustUnavailable)
        #expect(custodian.next == "sudo rv mcp custodian install")
    }
}
