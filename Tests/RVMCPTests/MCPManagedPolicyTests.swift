import Foundation
import RVIsolation
import RVPolicy
import Testing
@testable import RVMCP

@Suite("MCP under organization policy")
struct MCPManagedPolicyTests {
    private func organization(_ json: String) throws -> ManagedPolicy {
        try ManagedPolicy.decode(Data(json.utf8)).get()
    }

    @Test func organizationOnlyTightensToolDecisions() throws {
        var configuration = MCPConfiguration(
            defaultDecision: .allow,
            servers: [MCPServerDefinition(name: "github", command: "gh-mcp", tools: MCPToolPolicy(deny: ["merge_*"]))])
        let github = try #require(configuration.server(named: "github"))
        configuration.managed = try organization("""
            {"version": 1, "mcp": {"deny": ["*/delete_*"], "ask": ["github/create_*"], "allow": ["github/merge_*"]}}
            """)
        #expect(configuration.decision(server: github, tool: "delete_repo") == .deny)
        #expect(configuration.decision(server: github, tool: "create_issue") == .ask)
        #expect(configuration.decision(server: github, tool: "merge_pr") == .deny)
        #expect(configuration.decision(server: github, tool: "get_issue") == .allow)

        configuration.managed = try organization(#"{"version": 1, "mcp": {"defaultDecision": "ask", "allow": ["*/get_*"]}}"#)
        #expect(configuration.decision(server: github, tool: "list_prs") == .ask)
        #expect(configuration.decision(server: github, tool: "get_issue") == .allow)
    }

    @Test func blockedAndDirectFollowTheOrganization() throws {
        var configuration = MCPConfiguration(
            servers: [MCPServerDefinition(name: "shell-exec", command: "sh-mcp")], direct: ["hosted"])
        configuration.managed = try organization(#"{"version": 1, "mcp": {"blocked": ["shell-*"], "allowDirect": false}}"#)
        func entry(_ name: String, command: String = "x") -> MCPHostEntry {
            MCPHostEntry(
                host: .cursor, scope: .user, configPath: "~/.cursor/mcp.json", name: name,
                transport: .stdio(command: command, args: []))
        }
        #expect(MCPInventoryRow.status(entry("shell-exec"), configuration: configuration, rvExecutable: "/usr/bin/rv") == .blocked)
        #expect(MCPInventoryRow.status(entry("hosted"), configuration: configuration, rvExecutable: "/usr/bin/rv") == .unreviewed)
        configuration.managed = nil
        #expect(MCPInventoryRow.status(entry("hosted"), configuration: configuration, rvExecutable: "/usr/bin/rv") == .direct)
    }

    @Test func plannerRefusesWhatTheOrganizationForbids() throws {
        var configuration = MCPConfiguration(servers: [
            MCPServerDefinition(name: "shell-exec", command: "sh-mcp"),
            MCPServerDefinition(name: "plain", command: "p"),
            MCPServerDefinition(name: "envy", command: "e", secrets: ["TOKEN": "HOST_TOKEN"]),
        ])
        let secrets = SecretsConfiguration(secrets: [
            SecretDefinition(name: "HOST_TOKEN", source: .hostEnvironment(variable: "T"), delivery: .environment)
        ])
        let resolver = SecretResolver { _ in .success(SecretValue("v")!) }
        func plan(_ name: String) -> MCPLaunchError? {
            if case .failure(let error) = MCPLaunchPlanner.plan(
                servers: [name], configuration: configuration, secrets: secrets, resolver: resolver, baseEnvironment: [:])
            {
                return error
            }
            return nil
        }
        configuration.managed = try organization("""
            {"version": 1, "mcp": {"blocked": ["shell-*"], "requireSandbox": true},
             "secrets": {"allowedSources": ["keychain"]}}
            """)
        #expect(plan("shell-exec") == .blocked("shell-exec"))
        guard case .sandbox(let reason)? = plan("plain") else {
            Issue.record("requireSandbox must refuse an unsandboxed server")
            return
        }
        #expect(reason.contains("organization policy requires a sandbox"))

        configuration.managed?.mcp.requireSandbox = false
        #expect(plan("plain") == nil)
        #expect(plan("envy") == .secretUnavailable(
            server: "envy", secret: "HOST_TOKEN", reason: "organization policy does not allow hostEnvironment secrets"))
    }
}
