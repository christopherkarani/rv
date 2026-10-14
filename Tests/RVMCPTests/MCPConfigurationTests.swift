#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
@testable import RVMCP

@Suite("MCPConfiguration")
struct MCPConfigurationTests {
    static let example = #"""
        {
          "version": 1,
          "defaultDecision": "ask",
          "servers": [
            { "name": "github", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "LOG_LEVEL": "info" },
              "secrets": { "GITHUB_PERSONAL_ACCESS_TOKEN": "GITHUB_TOKEN" },
              "tools": { "default": "allow", "deny": ["delete_*"], "ask": ["create_pull_request"] },
              "sandbox": { "network": false, "writable": ["~/.npm"] } }
          ],
          "direct": ["stripe"],
          "blocked": ["filesystem"]
        }
        """#

    private func decode(_ text: String) -> Result<MCPConfiguration, MCPConfigurationError> {
        MCPConfiguration.decode(Data(text.utf8))
    }

    @Test func decodesTheDocumentedExample() throws {
        let configuration = try decode(Self.example).get()
        let github = try #require(configuration.server(named: "github"))
        #expect(github.args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(github.secrets == ["GITHUB_PERSONAL_ACCESS_TOKEN": "GITHUB_TOKEN"])
        #expect(github.sandbox == MCPSandboxPolicy(network: false, writable: ["~/.npm"]))
        #expect(configuration.direct == ["stripe"])
        #expect(configuration.blocked == ["filesystem"])
    }

    @Test func toolDecisionPrecedence() throws {
        let configuration = try decode(Self.example).get()
        let github = try #require(configuration.server(named: "github"))
        #expect(configuration.decision(server: github, tool: "delete_repo") == .deny)
        #expect(configuration.decision(server: github, tool: "create_pull_request") == .ask)
        #expect(configuration.decision(server: github, tool: "list_issues") == .allow)
        let bare = MCPServerDefinition(name: "x", command: "x")
        #expect(configuration.decision(server: bare, tool: "anything") == .ask)
        let overlap = MCPToolPolicy(defaultDecision: .allow, allow: ["*"], ask: ["write_*"], deny: ["write_secret"])
        #expect(overlap.decision(for: "write_secret", fallback: .deny) == .deny)
        #expect(overlap.decision(for: "write_file", fallback: .deny) == .ask)
        #expect(overlap.decision(for: "read", fallback: .deny) == .allow)
    }

    @Test func globs() {
        #expect(MCPGlob.matches("delete_*", "delete_repo"))
        #expect(MCPGlob.matches("*", ""))
        #expect(MCPGlob.matches("a?c", "abc"))
        #expect(MCPGlob.matches("*_issue*", "create_issue_comment"))
        #expect(MCPGlob.matches("delete_*", "undelete_x") == false)
        #expect(MCPGlob.matches("a?c", "ac") == false)
    }

    @Test func rejectsInvalidDocuments() {
        let cases: [(String, String)] = [
            (#"{"version":2}"#, "version"),
            (#"{"version":1,"extra":true}"#, "unknown key extra"),
            (#"{"version":1,"servers":[{"name":"a b","command":"x"}]}"#, "server name"),
            (#"{"version":1,"servers":[{"name":"a"}]}"#, "needs a command"),
            (#"{"version":1,"servers":[{"name":"a","command":"x"},{"name":"a","command":"y"}]}"#, "defined twice"),
            (#"{"version":1,"servers":[{"name":"a","command":"x"}],"blocked":["a"]}"#, "both blocked"),
            (#"{"version":1,"direct":["a"],"blocked":["a"]}"#, "both blocked"),
            (#"{"version":1,"servers":[{"name":"a","command":"x","env":{"K":"1"},"secrets":{"K":"S"}}]}"#, "both env and secrets"),
            (#"{"version":1,"servers":[{"name":"a","command":"x","tools":{"default":"maybe"}}]}"#, "allow, ask or deny"),
            (#"{"version":1,"servers":[{"name":"a","command":"x","tool":{}}]}"#, "unknown key tool"),
            (#"{"version":1,"servers":[{"name":"a","command":"x","sandbox":{"writable":["rel"]}}]}"#, "absolute"),
            (#"{"version":1,"servers":[{"name":"a","command":"x","secrets":{"K":"not a name"}}]}"#, "invalid secret"),
        ]
        for (text, fragment) in cases {
            guard case .failure(let error) = decode(text) else {
                Issue.record("accepted \(text)")
                continue
            }
            #expect(error.message.contains(fragment), "\(text) -> \(error.message)")
        }
    }

    @Test func writeThenLoadRoundTripsOwnerOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try decode(Self.example).get()
        let signer = try #require(MCPApprovalKeyStore.file(configDirectory: directory).loadOrCreate())
        _ = try configuration.write(configDirectory: directory, signer: signer).get()
        var info = stat()
        #expect(stat(MCPConfiguration.fileURL(configDirectory: directory).path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try MCPConfiguration.load(configDirectory: directory).get() == configuration)
    }

    @Test func missingFileIsEmptyAndUnsafeFileIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try MCPConfiguration.load(configDirectory: directory).get() == MCPConfiguration())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = MCPConfiguration.fileURL(configDirectory: directory)
        try Data(#"{"version":1}"#.utf8).write(to: file)
        chmod(file.path, 0o666)
        guard case .failure(.unsafeFile) = MCPConfiguration.load(configDirectory: directory) else {
            Issue.record("group-writable mcp.json was accepted")
            return
        }
    }

    @Test func unknownKeysAreEscaped() {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let top = "{\"version\":1,\"\\u001b[2J\\u001b[H\(sentence)\":true}"
        guard case .failure(let topError) = decode(top) else {
            Issue.record("unknown key was accepted")
            return
        }
        #expect(topError.message.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(topError.message.contains("\\u001b[2J"))
        #expect(topError.message.contains("unknown key"))
        let line = "{\"version\":1,\"servers\":[{\"name\":\"github\",\"command\":\"x\",\"env\":{\"\\u2028\(sentence)\":\"v\"}}]}"
        guard case .failure(let envError) = decode(line) else {
            Issue.record("env key was accepted")
            return
        }
        #expect(envError.message.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(envError.message.contains("\\u2028"))
        #expect(envError.message.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" }).map(String.init).contains(sentence) == false)
    }
}
