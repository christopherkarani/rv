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

    static let ruled = #"""
        {"version": 1, "servers": [{"name": "db", "command": "db-mcp", "tools": {"default": "allow",
          "ask": [{"tool": "query", "when": {"/database": {"==": "prod"}}}],
          "deny": ["drop_*", {"tool": "query", "when": {"/sql": {"glob": "DROP *"}}}]}}]}
        """#

    @Test func argumentRulesDecideByTheCallsArguments() throws {
        let configuration = try decode(Self.ruled).get()
        let db = try #require(configuration.server(named: "db"))
        func args(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }
        #expect(db.tools.deny == ["drop_*"])
        #expect(db.tools.rules.map(\.decision) == [.ask, .deny])
        #expect(configuration.decision(server: db, tool: "query", arguments: try args(#"{"database":"test"}"#)) == .allow)
        #expect(configuration.decision(server: db, tool: "query", arguments: try args(#"{"database":"prod"}"#)) == .ask)
        #expect(configuration.decision(
            server: db, tool: "query", arguments: try args(#"{"database":"test","sql":"DROP TABLE t"}"#)) == .deny)
        #expect(configuration.decision(server: db, tool: "query") == .allow)
        #expect(configuration.decision(server: db, tool: "drop_table", arguments: try args("{}")) == .deny)
        #expect(configuration.hasArgumentRules(server: db, tool: "query"))
        #expect(configuration.hasArgumentRules(server: db, tool: "list") == false)

        var untrusted = configuration
        untrusted.untrusted = true
        #expect(untrusted.decision(server: db, tool: "query", arguments: try args(#"{"database":"test"}"#)) == .ask)
    }

    @Test func argumentRulesRoundTripAndRejectMistakes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try decode(Self.ruled).get()
        let signer = try #require(MCPApprovalKeyStore.file(configDirectory: directory).loadOrCreate())
        _ = try configuration.write(configDirectory: directory, signer: signer).get()
        #expect(try MCPConfiguration.load(configDirectory: directory).get() == configuration)
        #expect(configuration.encoded().compactText.contains(#""deny":["drop_*",{"tool":"query","when":{"/sql":{"glob":"DROP *"}}}]"#))

        guard case .failure(let error) = decode(
            #"{"version":1,"servers":[{"name":"db","command":"x","tools":{"ask":[{"tool":"q"}]}}]}"#)
        else {
            Issue.record("accepted a rule without when")
            return
        }
        #expect(error.message.contains("server db tools.ask: tool rule for q needs a non-empty"), "\(error.message)")
    }

    @Test func toolModeRoundTripsAndDefaultsToDirect() throws {
        #expect(try decode(#"{"version":1}"#).get().toolMode == .direct)
        let search = try decode(#"{"version":1,"toolMode":"search"}"#).get()
        #expect(search.toolMode == .search)
        #expect(try MCPConfiguration.decode(Data(search.encoded().compactText.utf8)).get() == search)
        #expect(MCPConfiguration().encoded().compactText.contains("toolMode") == false)
        guard case .failure(let error) = decode(#"{"version":1,"toolMode":"lazy"}"#) else {
            Issue.record("accepted an unknown tool mode")
            return
        }
        #expect(error.message == #"mcp.json is invalid: toolMode must be "direct" or "search""#)
    }

    static let remote = #"""
        {"version": 1, "servers": [
          {"name": "linear", "url": "https://mcp.linear.app/mcp", "tools": {"default": "allow"}},
          {"name": "gh", "url": "https://api.githubcopilot.com/mcp/", "transport": "http",
           "headers": {"Authorization": "Bearer ${secret:GITHUB_PAT}", "X-MCP-Toolsets": "repos"}},
          {"name": "local", "url": "http://127.0.0.1:8931/sse", "transport": "sse"}
        ]}
        """#

    @Test func remoteServersDecodeAndRoundTrip() throws {
        let configuration = try decode(Self.remote).get()
        let linear = try #require(configuration.server(named: "linear")?.remote)
        #expect(linear == MCPRemoteServer(url: try #require(URL(string: "https://mcp.linear.app/mcp"))))
        #expect(linear.transport == .http)
        let gh = try #require(configuration.server(named: "gh")?.remote)
        #expect(gh.headers == ["Authorization": "Bearer ${secret:GITHUB_PAT}", "X-MCP-Toolsets": "repos"])
        #expect(gh.secretNames == ["GITHUB_PAT"])
        #expect(configuration.server(named: "local")?.remote?.transport == .sse)
        #expect(configuration.server(named: "local")?.command == "")

        let text = configuration.encoded().compactText
        #expect(text.contains("command") == false)
        #expect(text.contains(#""transport":"sse""#))
        #expect(text.contains(#""transport":"http""#) == false)
        #expect(try MCPConfiguration.decode(Data(text.utf8)).get() == configuration)
    }

    @Test func remoteServersRefuseLocalKeysUnsafeURLsAndManagedHeaders() {
        func server(_ body: String) -> String { #"{"version":1,"servers":[{"name":"r",\#(body)}]}"# }
        let cases: [(String, String)] = [
            (server(#""url":"https://a.example","command":"x""#), "both command and url"),
            (server(#""url":"https://a.example","args":["x"]"#), "unknown key args"),
            (server(#""url":"https://a.example","env":{"K":"v"}"#), "unknown key env"),
            (server(#""url":"https://a.example","secrets":{"K":"S"}"#), "unknown key secrets"),
            (server(#""url":"https://a.example","sandbox":{}"#), "unknown key sandbox"),
            (server(#""command":"x","headers":{"A":"b"}"#), "unknown key headers"),
            (server(#""url":"http://a.example/mcp""#), "url must be https"),
            (server(#""url":"https://user:pw@a.example/mcp""#), "without credentials"),
            (server(#""url":"ftp://a.example""#), "url must be https"),
            (server(#""url":"not a url""#), "url must be https"),
            (server(#""url":"https://a.example/#frag""#), "fragment"),
            (server(#""url":"https://a.example/mcp?api_key=zzz""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?x=0123456789abcdefghijklmnop""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=https://user:pw@evil.example/x""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=https://evil.example/ghp_1234567890abcdefghij""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=//user:pw@evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=https%253A%252F%252Fuser%253Apw%2540evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?q=.ghp_1234567890abcdefghij""#), "secret in its query"),
            (server(#""url":"https://a.example/user:pw@evil.example/mcp""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest%23ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://ghp_1234567890abcdefghij.example/hook""#), "secret in its host"),
            (server(#""url":"https://user%3Apw%40evil.example/hook""#), "secret in its host"),
            (server(#""url":"https://a.example/sk-1234567890abcdefghijklmnop/mcp""#), "secret in its path"),
            (server(#""url":"https://a.example/.ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest/~ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/opt/ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=~ghp_1234567890abcdefghij""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=/opt/ghp_1234567890abcdefghij""#), "secret in its query"),
            (server(#""url":"https://a.example/mcp?next=https://user:pw@evil.example/a%20b""#), "secret in its query"),
            (server(#""url":"https://a.example/ingest%3Bghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/hook%3Ftoken=ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest%00ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/:pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=https%253A%252F%252Fuser%253Apwsecretvalue%2540evil.example%25""#), "secret in its query"),
            (server(#""url":"https://a.example/ingest%252Fghp_1234567890abcdefghij%25""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest|ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest%257Cghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest%2540ghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?token=ghp_1234567890abcdefghij%""#), "secret in its query"),
            (server(#""url":"https://a.example/:su&pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:su%26pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:su%3Fpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/:su%5Cpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=/:su&pwsecretvalue@evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/ingest|t=ghp_1234567890abcdef""#), "secret in its path"),
            (server(#""url":"https://a.example/ingest%2540t=ghp_12345678""#), "secret in its path"),
            (server(#""url":"https://a.example/user:su%2Fpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/:%2Fpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=user:su&pwsecretvalue%2Fmore@evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/in+ghp_12345678""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?token=%22ghp_1234567890abcdefghij%""#), "secret in its query"),
            (server(#""url":"https://a.example/ingest%E2%80%8Bghp_1234567890abcdefghij""#), "secret in its path"),
            (server(#""url":"https://a.example/x_ghp_12345678""#), "secret in its path"),
            (server(#""url":"https://a.example/x-ghp_12345678""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?t=x_ghp_12345678""#), "secret in its query"),
            (server(#""url":"https://a.example/user~:su&pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:su/pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:%2Fpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:/pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=user:%2Fsu&pwsecretvalue@evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/user~:/pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user!:/pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user%3A%2Fpwsecretvalue%40evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=user:/su&pwsecretvalue@evil.example""#), "secret in its query"),
            (server(#""url":"http://127.0.0.1/user:/pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user://pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:/%2Fpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/user:/%5Cpwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/mcp?next=user://su&pwsecretvalue@evil.example""#), "secret in its query"),
            (server(#""url":"https://a.example/user:/su?pwsecretvalue@evil.example""#), "secret in its path"),
            (server(#""url":"https://a.example/user:@pwsecretvalue@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/http://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/https://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/wss://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/postgres://supersecretpassword@db.example/app""#), "secret in its path"),
            (server(#""url":"https://a.example/HTTP://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/HTTPS://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/http:%2F%2Fsupersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/https:%2F%2Fsupersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/%68%74%74%70://supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/https:\\supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/https:\\\\supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/https://user:supersecretpassword@evil.example/hook""#), "secret in its path"),
            (server(#""url":"https://a.example/hook?next=https://supersecretpassword@collector.example""#), "secret in its query"),
            (server(#""url":"https://a.example/hook?next=https://supersecretpassword%40collector.example""#), "secret in its query"),
            (server(#""url":"https://supersecretpassword@evil.example/hook""#), "without credentials"),
            (server(#""url":"https://supersecretpassword%40evil.example/hook""#), "secret in its host"),
            (server(#""url":"https://supersecretpassword%2540evil.example/hook""#), "secret in its host"),
            (server(#""url":"HTTPS://supersecretpassword%40evil.example/hook""#), "secret in its host"),
            (server(#""url":"https://a.example","transport":"ws""#), #"transport must be "http" or "sse""#),
            (server(#""url":"https://a.example","headers":{"Mcp-Session-Id":"x"}"#), "rv sets Mcp-Session-Id"),
            (server(#""url":"https://a.example","headers":{"host":"x"}"#), "rv sets host"),
            (server(#""url":"https://a.example","headers":{"Content-Type":"x"}"#), "rv sets Content-Type"),
            (server(#""url":"https://a.example","headers":{"Bad Name":"x"}"#), "header name"),
            (server(#""url":"https://a.example","headers":{"A":"x\ny"}"#), "line break"),
            (server(#""url":"https://a.example","headers":{"A":"${secret:}"}"#), "malformed ${secret:NAME}"),
            (server(#""url":"https://a.example","headers":{"A":1}"#), "must be a string"),
        ]
        for (text, fragment) in cases {
            guard case .failure(let error) = decode(text) else {
                Issue.record("accepted \(text)")
                continue
            }
            #expect(error.message.contains(fragment), "\(text) -> \(error.message)")
        }
        for loopback in ["http://localhost:9/mcp", "http://127.0.0.1/mcp", "http://127.0.0.2/mcp", "http://[::1]:8080/sse", "http://[::ffff:127.0.0.1]/mcp"] {
            #expect((try? decode(server(#""url":"\#(loopback)""#)).get()) != nil, "\(loopback)")
        }
        // Browser/aton spellings of 127.0.0.1 are not canonical hosts.
        for disguised in ["http://127.1/mcp", "http://2130706433/mcp", "http://0x7f000001/mcp", "http://0177.0.0.1/mcp", "https://127.1/mcp", "http://localhost./mcp", "http://[fe80::1%25eth0]/mcp"] {
            #expect((try? decode(server(#""url":"\#(disguised)""#)).get()) == nil, "\(disguised)")
        }
        #expect((try? decode(server(#""url":"https://a.example/mcp?v=1""#)).get()) != nil)
    }

    @Test func largeIntegersCompareExactly() throws {
        let big = try JSONValue.parse(Data("9007199254740993".utf8))
        #expect(big.domainValue == .string("\u{0}" + "9007199254740993"))
        #expect(big.domainValue != (try JSONValue.parse(Data("\"9007199254740993\"".utf8))).domainValue)
        #expect(try JSONValue.parse(Data("12.5".utf8)).domainValue == .number(12.5))
        #expect(try JSONValue.parse(Data(#"{"a":[true,null]}"#.utf8)).domainValue
            == .object(["a": .array([.bool(true), .null])]))
        for spelling in ["9007199254740993.0", "9007199254740993e0", "9.007199254740993e15"] {
            let value = try JSONValue.parse(Data(spelling.utf8)).domainValue
            #expect(value == .string("\u{0}" + "9007199254740993"))
        }
        #expect(try JSONValue.parse(Data("4611686018427387905.0".utf8)).domainValue == .string("\u{0}" + "4611686018427387905"))
        #expect(try JSONValue.parse(Data("-9007199254740993.0".utf8)).domainValue == .string("\u{0}" + "-9007199254740993"))
        #expect(try JSONValue.parse(Data("2.0".utf8)).domainValue == .number(2))
        #expect(try JSONValue.parse(Data("-12.5".utf8)).domainValue == .number(-12.5))
        for spelling in ["12.50", "1.25e1", "125e-1"] {
            #expect(try JSONValue.parse(Data(spelling.utf8)).domainValue == .number(12.5), "\(spelling)")
        }
        #expect(try JSONValue.parse(Data("10.5".utf8)).domainValue == .number(10.5))
        #expect(try JSONValue.parse(Data("10.25".utf8)).domainValue == .number(10.25))
        #expect(try JSONValue.parse(Data("2251799813685248.5".utf8)).domainValue == .number(2251799813685248.5))
        #expect(try JSONValue.parse(Data("4503599627370495.5".utf8)).domainValue == .number(4503599627370495.5))
        for spelling in [
            "9007199254740991.4", "9007199254740990.1", "9007199254740990.9", "-9007199254740990.1",
            "4503599627370496.4", "1.0000000000000001",
            "2251799813685248.4", "2251799813685248.6", "4503599627370495.4", "4503599627370495.6",
            "12.500000000000001",
        ] {
            #expect(try JSONValue.parse(Data(spelling.utf8)).domainValue == .string("\u{0}" + spelling))
        }
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
}
