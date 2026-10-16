import Foundation
import Synchronization
import Testing
@testable import RVMCP

final class FakeApprovals: Sendable {
    let granted = Mutex<Set<String>>([])
    let forged = Mutex<Set<String>>([])
    let requested = Mutex<[String]>([])

    var gate: MCPApprovalGate {
        MCPApprovalGate(
            consumeGrant: { server, tool, hash in
                let key = "\(server)/\(tool)/\(hash)"
                if self.granted.withLock({ $0.remove(key) }) != nil { return .granted(id: "grant1") }
                if self.forged.withLock({ $0.remove(key) }) != nil { return .forged(id: "forged1") }
                return .none
            },
            request: { server, tool, _, _ in
                self.requested.withLock { $0.append("\(server)/\(tool)") }
                return MCPApprovalTicket(id: "req1", code: "ABCDE-FGHJK")
            })
    }
}

struct GatewayHarness {
    var core: MCPGatewayCore
    let approvals = FakeApprovals()

    init(_ configuration: MCPConfiguration, secrets: [String: [(name: String, value: String)]] = [:]) {
        let upstreams = configuration.servers.map {
            MCPGatewayCore.Upstream(definition: $0, secretValues: secrets[$0.name] ?? [])
        }
        let approvals = self.approvals
        core = MCPGatewayCore(configuration: configuration, upstreams: upstreams, approvals: approvals.gate, clock: { Date() })
    }

    /// Starts and answers every upstream initialize.
    mutating func ready() -> [MCPGatewayOutput] {
        var outputs: [MCPGatewayOutput] = []
        for case .toUpstream(let server, let message) in core.start() {
            outputs += core.handle(.upstream(server: server, message: .object([
                "jsonrpc": .string("2.0"), "id": message["id"] ?? .null,
                "result": .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:])]),
            ])))
        }
        return outputs
    }

    mutating func client(_ text: String) -> [MCPGatewayOutput] {
        core.handle(.client(try! JSONValue.parse(text)))
    }

    mutating func upstream(_ server: String, _ text: String) -> [MCPGatewayOutput] {
        core.handle(.upstream(server: server, message: try! JSONValue.parse(text)))
    }
}

extension [MCPGatewayOutput] {
    var toClient: [JSONValue] { compactMap { if case .toClient(let m) = $0 { m } else { nil } } }
    var toUpstream: [(String, JSONValue)] { compactMap { if case .toUpstream(let s, let m) = $0 { (s, m) } else { nil } } }
    var audits: [MCPCallRecord] { compactMap { if case .audit(let r) = $0 { r } else { nil } } }
    var logs: [String] { compactMap { if case .log(let l) = $0 { l } else { nil } } }
}

@Suite("MCPGatewayCore")
struct MCPGatewayCoreTests {
    static let github = MCPServerDefinition(
        name: "github", command: "gh-mcp",
        tools: MCPToolPolicy(defaultDecision: .allow, ask: ["create_*"], deny: ["delete_*"]))
    static let notes = MCPServerDefinition(name: "notes", command: "notes-mcp", tools: MCPToolPolicy(defaultDecision: .allow))

    @Test func initializesUpstreamsAndAnswersTheClientItself() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        let started = harness.core.start()
        #expect(started.toUpstream.count == 1)
        #expect(started.toUpstream.first?.1["method"] == .string("initialize"))
        #expect(started.toUpstream.first?.1["params"]?["capabilities"] == .object([:]))

        let reply = harness.client(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        #expect(reply.toClient.first?["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(reply.toClient.first?["result"]?["capabilities"]?["tools"] != nil)
        let unknown = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(unknown.toClient.first?["result"]?["protocolVersion"] == .string(MCPGatewayCore.upstreamVersion))
        #expect(harness.client(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#).toClient.first?["result"] == .object([:]))
        #expect(harness.client(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#).toClient.first?["error"]?["code"] == .int(-32601))
        #expect(harness.client(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).isEmpty)
        #expect(harness.client(#"{"id":4,"method":"ping"}"#).toClient.first?["error"]?["code"] == .int(-32600))
        #expect(harness.core.handle(.clientUnparseable).toClient.first?["error"]?["code"] == .int(-32700))
    }

    @Test func toolsListWaitsForUpstreamsThenSendsNotificationsInitialized() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        let initialize = harness.core.start().toUpstream[0].1
        #expect(harness.client(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#).isEmpty)
        let afterInit = harness.core.handle(.upstream(server: "github", message: .object([
            "jsonrpc": .string("2.0"), "id": initialize["id"] ?? .null, "result": .object([:]),
        ])))
        #expect(afterInit.toUpstream.map(\.1["method"]) == [.string("notifications/initialized"), .string("tools/list")])
    }

    @Test func singleServerKeepsNamesHidesDeniedAndMarksAsk() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let list = harness.client(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        let id = list.toUpstream[0].1["id"]?.intValue ?? -1
        let reply = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"list_issues","inputSchema":{"type":"object"}},{"name":"delete_repo"},{"name":"create_issue","description":"Open one"}]}}"#)
        let tools = reply.toClient.first?["result"]?["tools"]?.arrayValue ?? []
        #expect(reply.toClient.first?["id"] == .int(7))
        #expect(tools.map { $0["name"] } == [.string("list_issues"), .string("create_issue")])
        #expect(tools[1]["description"] == .string("[rv: needs the user's approval] Open one"))
        #expect(tools[0]["inputSchema"] == .object(["type": .string("object")]))
    }

    @Test func multipleServersArePrefixedAndPagesAreFollowed() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github, Self.notes]))
        _ = harness.ready()
        let fanout = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).toUpstream
        #expect(Set(fanout.map(\.0)) == ["github", "notes"])
        let githubID = fanout.first { $0.0 == "github" }?.1["id"]?.intValue ?? -1
        let notesID = fanout.first { $0.0 == "notes" }?.1["id"]?.intValue ?? -1

        let page = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(githubID),"result":{"tools":[{"name":"a"}],"nextCursor":"p2"}}"#)
        #expect(page.toUpstream.first?.1["params"]?["cursor"] == .string("p2"))
        let secondID = page.toUpstream.first?.1["id"]?.intValue ?? -1
        #expect(harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(secondID),"result":{"tools":[{"name":"b"}]}}"#).toClient.isEmpty)
        let done = harness.upstream("notes", #"{"jsonrpc":"2.0","id":\#(notesID),"result":{"tools":[{"name":"write"}]}}"#)
        let names = done.toClient.first?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["github__a", "github__b", "notes__write"])

        let call = harness.client(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"notes__write","arguments":{"text":"hi"}}}"#)
        #expect(call.toUpstream.first?.0 == "notes")
        #expect(call.toUpstream.first?.1["params"]?["name"] == .string("write"))
        let unknown = harness.client(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope__x"}}"#)
        #expect(unknown.toClient.first?["error"]?["code"] == .int(-32602))
    }

    @Test func allowedCallIsForwardedMappedBackAndAudited() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"list_issues","arguments":{"repo":"x","state":"open"},"_meta":{"progressToken":5}}}"#)
        let forwarded = call.toUpstream[0].1
        #expect(forwarded["params"]?["_meta"]?["progressToken"] == .int(5))
        let upstreamID = forwarded["id"]?.intValue ?? -1
        let reply = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(upstreamID),"result":{"content":[{"type":"text","text":"ok"}]}}"#)
        #expect(reply.toClient.first?["id"] == .string("c1"))
        #expect(reply.toClient.first?["result"]?["content"]?.arrayValue?.first?["text"] == .string("ok"))
        let record = reply.audits.first
        #expect(record?.decision == .allow)
        #expect(record?.argumentKeys == ["repo", "state"])
        #expect(record?.isError == false)
        #expect(record?.durationMilliseconds != nil)
    }

    @Test func argumentRulesDecideEachCall() throws {
        let configuration = try MCPConfiguration.decode(Data(#"""
            {"version": 1, "servers": [{"name": "db", "command": "db-mcp", "tools": {"default": "allow",
              "ask": [{"tool": "query", "when": {"/database": {"==": "prod"}}}],
              "deny": [{"tool": "query", "when": {"/sql": {"glob": "DROP *"}}}]}}]}
            """#.utf8)).get()
        var harness = GatewayHarness(configuration)
        _ = harness.ready()

        let list = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listID = list.toUpstream[0].1["id"]?.intValue ?? -1
        let tools = harness.upstream("db", #"{"jsonrpc":"2.0","id":\#(listID),"result":{"tools":[{"name":"query","description":"Run SQL"},{"name":"tables"}]}}"#)
            .toClient.first?["result"]?["tools"]?.arrayValue ?? []
        #expect(tools.map { $0["name"] } == [.string("query"), .string("tables")])
        #expect(tools[0]["description"] == .string("[rv: some arguments need the user's approval or are refused] Run SQL"))
        #expect(tools[1]["description"] == nil)

        let allowed = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"database":"test","sql":"SELECT 1"}}}"#)
        #expect(allowed.toUpstream.count == 1)

        let asked = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query","arguments":{"database":"prod","sql":"SELECT 1"}}}"#)
        #expect(asked.toUpstream.isEmpty)
        #expect(asked.audits.first?.decision == .ask)

        let denied = harness.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query","arguments":{"database":"test","sql":"DROP TABLE users"}}}"#)
        #expect(denied.toUpstream.isEmpty)
        #expect(denied.audits.first?.decision == .deny)
        #expect(denied.toClient.first?["result"]?["isError"] == .bool(true))
    }

    @Test func searchModeListsTwoToolsAndRoutesCallsThroughTheSamePolicy() throws {
        let configuration = try MCPConfiguration.decode(Data(#"""
            {"version": 1, "toolMode": "search", "servers": [{"name": "db", "command": "db-mcp",
              "tools": {"default": "allow", "ask": ["write"], "deny": ["drop"]}}]}
            """#.utf8)).get()
        var harness = GatewayHarness(configuration)
        _ = harness.ready()

        let list = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(list.toUpstream.isEmpty)
        let meta = list.toClient.first?["result"]?["tools"]?.arrayValue ?? []
        #expect(meta.map { $0["name"] } == [.string("rv_search_tools"), .string("rv_call_tool")])
        #expect(meta[1]["inputSchema"]?["required"] == .array([.string("name")]))

        let upstreamTools = #"[{"name":"query","description":"Run SQL","inputSchema":{"type":"object"}},{"name":"write","description":"Write SQL rows"},{"name":"drop","description":"Drop a SQL table"},{"name":"tables","description":"List tables"}]"#
        func search(_ id: Int, _ arguments: String) -> JSONValue? {
            let asked = harness.client(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"rv_search_tools","arguments":\#(arguments)}}"#)
            let listID = asked.toUpstream.first?.1["id"]?.intValue ?? -1
            #expect(asked.toUpstream.first?.1["method"] == .string("tools/list"))
            return harness.upstream("db", #"{"jsonrpc":"2.0","id":\#(listID),"result":{"tools":\#(upstreamTools)}}"#)
                .toClient.first?["result"]
        }
        let sql = try #require(search(2, #"{"query":"SQL"}"#))
        let found = sql["structuredContent"]?["tools"]?.arrayValue ?? []
        #expect(found.map { $0["name"] } == [.string("query"), .string("write")])
        #expect(found[1]["description"] == .string("[rv: needs the user's approval] Write SQL rows"))
        #expect(sql["structuredContent"]?["total"]?.intValue == 2)
        #expect(sql["content"]?.arrayValue?.first?["text"]?.stringValue?.contains(#""name":"query""#) == true)
        let everything = try #require(search(3, #"{}"#))
        #expect(everything["structuredContent"]?["tools"]?.arrayValue?.map { $0["name"] }
            == [.string("query"), .string("write"), .string("tables")])
        let byName = try #require(search(4, #"{"query":"table","limit":1}"#))
        #expect(byName["structuredContent"]?["tools"]?.arrayValue?.map { $0["name"] } == [.string("tables")])
        #expect(byName["structuredContent"]?["total"]?.intValue == 1)

        let run = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rv_call_tool","arguments":{"name":"query","arguments":{"sql":"SELECT 1"}}}}"#)
        let forwarded = try #require(run.toUpstream.first?.1)
        #expect(forwarded["params"]?["name"] == .string("query"))
        #expect(forwarded["params"]?["arguments"] == .object(["sql": .string("SELECT 1")]))
        let done = harness.upstream("db", #"{"jsonrpc":"2.0","id":\#(forwarded["id"]?.intValue ?? -1),"result":{"content":[{"type":"text","text":"1"}]}}"#)
        #expect(done.toClient.first?["id"] == .int(5))
        #expect(done.audits.first.map { ($0.server, $0.tool, $0.decision) } ?? ("", "", .deny) == ("db", "query", .allow))

        let asked = harness.client(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rv_call_tool","arguments":{"name":"write","arguments":{"row":1}}}}"#)
        #expect(asked.toUpstream.isEmpty)
        #expect(asked.audits.first?.decision == .ask)
        #expect(asked.audits.first?.tool == "write")

        let denied = harness.client(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rv_call_tool","arguments":{"name":"drop","arguments":{}}}}"#)
        #expect(denied.toUpstream.isEmpty)
        #expect(denied.audits.first?.decision == .deny)

        for bad in [#"{}"#, #"{"name":"query","arguments":[1]}"#, #"{"name":"rv_call_tool"}"#] {
            let refused = harness.client(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"rv_call_tool","arguments":\#(bad)}}"#)
            #expect(refused.toUpstream.isEmpty)
            #expect(refused.toClient.first?["result"]?["isError"] == .bool(true))
        }
    }

    @Test func deniedCallNeverReachesTheUpstream() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let reply = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_repo","arguments":{"repo":"x"}}}"#)
        #expect(reply.toUpstream.isEmpty)
        #expect(reply.toClient.first?["result"]?["isError"] == .bool(true))
        #expect(reply.audits.first?.decision == .deny)
    }

    @Test func askRecordsARequestThenAGrantLetsTheSameCallThroughOnce() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t","body":"b"}}}"#
        let paused = harness.client(call)
        #expect(paused.toUpstream.isEmpty)
        let text = paused.toClient.first?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("rv mcp approve req1"))
        #expect(paused.audits.first?.decision == .ask)
        #expect(harness.approvals.requested.withLock { $0 } == ["github/create_issue"])

        let hash = JSONValue.object(["body": .string("b"), "title": .string("t")]).canonicalHash
        _ = harness.approvals.granted.withLock { $0.insert("github/create_issue/\(hash)") }
        let allowed = harness.client(call)
        #expect(allowed.toUpstream.first?.1["params"]?["name"] == .string("create_issue"))
        let id = allowed.toUpstream.first?.1["id"]?.intValue ?? -1
        let done = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[]}}"#)
        #expect(done.audits.first?.approvalID == "grant1")
        #expect(harness.client(call).toUpstream.isEmpty)
    }

    @Test func cancellationIsMappedAndTheLateResponseDropped() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"list_issues"}}"#)
        let upstreamID = call.toUpstream[0].1["id"]?.intValue ?? -1
        let cancel = harness.client(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42,"reason":"user"}}"#)
        #expect(cancel.toUpstream.first?.1["params"]?["requestId"] == .int(upstreamID))
        #expect(harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(upstreamID),"result":{}}"#).isEmpty)
    }

    @Test func secretValuesAreScrubbedFromEverythingTheUpstreamReturns() {
        var harness = GatewayHarness(
            MCPConfiguration(servers: [Self.github]), secrets: ["github": [("GITHUB_TOKEN", "ghp_REALVALUE123")]])
        _ = harness.ready()
        let list = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listID = list.toUpstream[0].1["id"]?.intValue ?? -1
        let tools = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(listID),"result":{"tools":[{"name":"t","description":"uses ghp_REALVALUE123"}]}}"#)
        #expect(tools.toClient.first?.compactText.contains("ghp_REALVALUE123") == false)
        let call = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"t"}}"#)
        let id = call.toUpstream[0].1["id"]?.intValue ?? -1
        let reply = harness.upstream("github", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"token=ghp_REALVALUE123!"}]}}"#)
        #expect(reply.toClient.first?["result"]?["content"]?.arrayValue?.first?["text"] == .string("token=[redacted:GITHUB_TOKEN]!"))
    }

    @Test func upstreamRequestsAreRefusedAndListChangedForwarded() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        let sampling = harness.upstream("github", #"{"jsonrpc":"2.0","id":"s1","method":"sampling/createMessage","params":{}}"#)
        #expect(sampling.toUpstream.first?.1["error"]?["code"] == .int(-32601))
        let ping = harness.upstream("github", #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#)
        #expect(ping.toUpstream.first?.1["result"] == .object([:]))
        let changed = harness.upstream("github", #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#)
        #expect(changed.toClient.first?["method"] == .string("notifications/tools/list_changed"))
        #expect(harness.upstream("github", #"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#).isEmpty)
    }

    @Test func upstreamExitFailsInFlightCallsAndLaterCalls() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.ready()
        _ = harness.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_issues"}}"#)
        let exited = harness.core.handle(.upstreamExited(server: "github"))
        #expect(exited.toClient.first?["id"] == .int(5))
        #expect(exited.toClient.first?["error"]?["code"] == .int(-32603))
        #expect(exited.audits.first?.reason == "upstream exited")
        let later = harness.client(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_issues"}}"#)
        #expect(later.toClient.first?["error"] != nil)
        let list = harness.client(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        #expect(list.toClient.first?["result"]?["tools"] == .array([]))
    }

    @Test func upstreamThatFailsToStartReleasesWaitingClients() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github, Self.notes]))
        let started = harness.core.start().toUpstream
        _ = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let notesInit = started.first { $0.0 == "notes" }?.1["id"] ?? .null
        _ = harness.core.handle(.upstream(server: "notes", message: .object([
            "jsonrpc": .string("2.0"), "id": notesInit, "result": .object([:]),
        ])))
        let released = harness.core.handle(.upstreamExited(server: "github"))
        #expect(released.toUpstream.contains { $0.0 == "notes" && $0.1["method"] == .string("tools/list") })
    }

    @Test func serverNamesContainingSeparatorUseTheLongestPrefix() {
        let payments = MCPServerDefinition(name: "payments", command: "pay", tools: MCPToolPolicy(defaultDecision: .allow))
        let v2 = MCPServerDefinition(name: "payments__v2", command: "pay2", tools: MCPToolPolicy(defaultDecision: .allow))
        var harness = GatewayHarness(MCPConfiguration(servers: [payments, v2]))
        _ = harness.ready()
        let fanout = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).toUpstream
        let paymentsID = fanout.first { $0.0 == "payments" }?.1["id"]?.intValue ?? -1
        let v2ID = fanout.first { $0.0 == "payments__v2" }?.1["id"]?.intValue ?? -1
        _ = harness.upstream("payments", #"{"jsonrpc":"2.0","id":\#(paymentsID),"result":{"tools":[{"name":"v2__refund"},{"name":"charge"}]}}"#)
        let listed = harness.upstream("payments__v2", #"{"jsonrpc":"2.0","id":\#(v2ID),"result":{"tools":[{"name":"refund"}]}}"#)
        let names = listed.toClient.first?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("payments__charge"))
        #expect(names.filter { $0 == "payments__v2__refund" }.count == 1)

        let refund = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"payments__v2__refund"}}"#)
        #expect(refund.toUpstream.first?.0 == "payments__v2")
        #expect(refund.toUpstream.first?.1["params"]?["name"] == .string("refund"))

        let charge = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"payments__charge"}}"#)
        #expect(charge.toUpstream.first?.0 == "payments")
        #expect(charge.toUpstream.first?.1["params"]?["name"] == .string("charge"))

        let unknown = harness.client(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such"}}"#)
        #expect(unknown.toClient.first?["error"]?["message"]?.stringValue?.contains("Unknown tool") == true)
        #expect(unknown.toUpstream.isEmpty)

        let deniedV2 = MCPServerDefinition(
            name: "payments__v2", command: "pay2", tools: MCPToolPolicy(defaultDecision: .allow, deny: ["refund"]))
        var denied = GatewayHarness(MCPConfiguration(servers: [payments, deniedV2]))
        _ = denied.ready()
        let blocked = denied.client(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"payments__v2__refund"}}"#)
        #expect(blocked.toUpstream.isEmpty)
        #expect(blocked.audits.first?.server == "payments__v2")
        #expect(blocked.audits.first?.tool == "refund")
        #expect(blocked.audits.first?.decision == .deny)
    }

    @Test func scrubReplacesShortValuesJSONEscapesAndLongerSecretsFirst() {
        let scrubbed = MCPGatewayCore.scrub(
            .string("pin=x tail sk-abcdefghijklmnopqrst and a\\\"b"),
            secrets: [("PIN", "x"), ("API_KEY", "sk-abc"), ("TOKEN", "sk-abcdefghijklmnopqrst"), ("Q", "a\"b")])
        #expect(scrubbed == .string("pin=[redacted:PIN] tail [redacted:TOKEN] and [redacted:Q]"))
        let raw = MCPGatewayCore.scrub(.string("a\"b"), secrets: [("Q", "a\"b")])
        #expect(raw == .string("[redacted:Q]"))
    }

    @Test func initializeErrorsAreScrubbedBeforeTheyAreLogged() {
        var harness = GatewayHarness(
            MCPConfiguration(servers: [Self.github]), secrets: ["github": [("TOKEN", "sekret")]])
        let started = harness.core.start().toUpstream
        let id = started[0].1["id"] ?? .null
        let failed = harness.core.handle(.upstream(server: "github", message: .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .int(-1), "message": .string("bad sekret")]),
        ])))
        let logs = failed.compactMap { output -> String? in
            if case .log(let text) = output { return text }
            return nil
        }
        #expect(logs == ["MCP server github failed to initialize: bad [redacted:TOKEN]"])
        let later = harness.client(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_issues"}}"#)
        #expect(later.toClient.first?.compactText.contains("sekret") == false)
    }

    @Test func grantIsKeptWhenTheUpstreamIsNotReady() {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github]))
        _ = harness.core.start()
        _ = harness.core.handle(.upstreamExited(server: "github"))
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_issue","arguments":{"title":"t"}}}"#
        let hash = JSONValue.object(["title": .string("t")]).canonicalHash
        let key = "github/create_issue/\(hash)"
        _ = harness.approvals.granted.withLock { $0.insert(key) }
        let reply = harness.client(call)
        #expect(reply.toUpstream.isEmpty)
        #expect(reply.toClient.first?["error"]?["code"] == .int(-32603))
        #expect(harness.approvals.granted.withLock { $0.contains(key) })
        #expect(harness.approvals.requested.withLock { $0 }.isEmpty)
    }

    @Test func forgedNumberMarkerStringIsRefusedWhenRulesApply() throws {
        let config = try MCPConfiguration.decode(Data(
            #"{"version":1,"servers":[{"name":"notes","command":"fixture","tools":{"allow":[{"tool":"add","when":{"/account":{"==":9007199254740993}}}]}}]}"#.utf8)).get()
        var harness = GatewayHarness(config)
        _ = harness.ready()
        let reply = harness.client(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add","arguments":{"account":"\u00009007199254740993"}}}"#)
        #expect(reply.toUpstream.isEmpty)
        #expect(reply.audits.first?.decision == .deny)
    }

    @Test func ordinaryDecimalsForwardWhenNoRuleReadsThem() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.notes]))
        _ = harness.ready()
        let reply = harness.client(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"add","arguments":{"price":19.99,"temperature":0.7}}}"#)
        #expect(reply.audits.isEmpty)
        #expect(reply.toUpstream.first?.1["params"]?["arguments"]?["price"] == .number("19.99"))
        #expect(reply.toUpstream.first?.1["params"]?["arguments"]?["temperature"] == .number("0.7"))
    }

    @Test func anUpstreamCannotAnswerAnotherUpstreamsCall() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.github, Self.notes]))
        _ = harness.ready()
        let sent = harness.client(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"github__search","arguments":{}}}"#)
        let (server, message) = try #require(sent.toUpstream.first)
        #expect(server == "github")
        let id = try #require(message["id"]?.intValue)

        let forged = harness.upstream(
            "notes", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"forged"}]}}"#)
        #expect(forged.toClient.isEmpty)
        #expect(forged.audits.isEmpty)
        #expect(forged.logs.contains { $0.contains("owned by github") })

        let genuine = harness.upstream(
            "github", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"genuine"}]}}"#)
        #expect(genuine.toClient.first?.compactText.contains("genuine") == true)
        #expect(genuine.audits.first?.server == "github")
    }

    @Test func cyclingListCursorsEndPagination() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.notes]))
        _ = harness.ready()
        var outputs = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        var rounds = 0
        while let (_, request) = outputs.toUpstream.first, rounds < 10 {
            rounds += 1
            let id = try #require(request["id"]?.intValue)
            let cursor = rounds.isMultiple(of: 2) ? "a" : "b"
            outputs = harness.upstream(
                "notes",
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"t\#(rounds)","inputSchema":{"type":"object"}}],"nextCursor":"\#(cursor)"}}"#)
        }
        #expect(rounds < 10)
        #expect(outputs.toClient.first?["result"]?["tools"]?.arrayValue?.isEmpty == false)
    }

}

@Suite("MCPApprovalStore")
struct MCPApprovalStoreTests {
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rv-mcp-approvals-\(UUID().uuidString)")
    }

    static func store(_ directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) -> MCPApprovalStore {
        MCPApprovalStore(configDirectory: directory, keys: .file(configDirectory: directory), clock: clock)
    }

    @Test func requestGrantConsumeLifecycle() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.store(directory)
        let id = try #require(store.request(server: "gh", tool: "create", argumentsHash: "h1", argumentKeys: ["title"])?.id)
        #expect(store.request(server: "gh", tool: "create", argumentsHash: "h1", argumentKeys: ["title"])?.id == id)
        #expect(store.pending().map(\.id) == [id])
        #expect(store.consumeGrant(server: "gh", tool: "create", argumentsHash: "h1") == .none)
        #expect(store.grant(id: id)?.state == .granted)
        #expect(store.pending().isEmpty)
        #expect(store.consumeGrant(server: "gh", tool: "create", argumentsHash: "other") == .none)
        #expect(store.consumeGrant(server: "gh", tool: "create", argumentsHash: "h1") == .granted(id: id))
        #expect(store.consumeGrant(server: "gh", tool: "create", argumentsHash: "h1") == .none)
        #expect(store.grant(id: "missing") == nil)
    }

    @Test func oldRequestsExpire() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let then = Date(timeIntervalSince1970: 1_000_000)
        _ = Self.store(directory, clock: { then })
            .request(server: "gh", tool: "x", argumentsHash: "h", argumentKeys: [])
        let later = Self.store(directory, clock: { then.addingTimeInterval(25 * 3600) })
        #expect(later.pending().isEmpty)
    }

    @Test func capDropsPendingRequestsAndRefusesToEvictGrants() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Self.store(directory)
        let grant = try #require(store.request(server: "gh", tool: "keep", argumentsHash: "grant", argumentKeys: [])?.id)
        #expect(store.grant(id: grant) != nil)
        var oldestPending: String?
        for index in 0..<(MCPApprovalStore.maximumRequests - 1) {
            let id = try #require(store.request(server: "gh", tool: "t", argumentsHash: "p\(index)", argumentKeys: [])?.id)
            if oldestPending == nil { oldestPending = id }
        }
        #expect(store.pending().count == MCPApprovalStore.maximumRequests - 1)
        let newest = try #require(store.request(server: "gh", tool: "t", argumentsHash: "newest", argumentKeys: [])?.id)
        #expect(store.pending().map(\.id).contains(oldestPending) == false)
        #expect(store.pending().map(\.id).contains(newest))
        #expect(store.consumeGrant(server: "gh", tool: "keep", argumentsHash: "grant") == .granted(id: grant))

        let grants = Self.scratch()
        defer { try? FileManager.default.removeItem(at: grants) }
        let full = Self.store(grants)
        for index in 0..<MCPApprovalStore.maximumRequests {
            let id = try #require(full.request(server: "gh", tool: "g", argumentsHash: "g\(index)", argumentKeys: [])?.id)
            #expect(full.grant(id: id) != nil)
        }
        #expect(full.request(server: "gh", tool: "g", argumentsHash: "overflow", argumentKeys: []) == nil)
        #expect(full.consumeGrant(server: "gh", tool: "g", argumentsHash: "g0") != .none)
    }

    @Test func nonCanonicalIntegersCannotSlipPastADenyOrAsk() throws {
        let configuration = try MCPConfiguration.decode(Data(#"""
            {"version": 1, "toolMode": "search", "servers": [{"name": "pay", "command": "pay-mcp", "tools": {"default": "allow",
              "ask": [{"tool": "note", "when": {"/amount": {"==": 7}}}],
              "deny": [
                {"tool": "eq", "when": {"/amount": {"==": 9007199254740993}}},
                {"tool": "mem", "when": {"/amount": {"in": [9007199254740993, -9007199254740993]}}},
                {"tool": "gt", "when": {"/amount": {">": 9007199254740992}}},
                {"tool": "neg", "when": {"/amount": {"<": -9007199254740992}}},
                {"tool": "wide", "when": {"/amount": {">": 4611686018427387904}}},
                {"tool": "rounded", "when": {"/amount": {">": 9007199254740995.0}}},
                {"tool": "pass", "when": {"/amount": {"==": 1}}},
                {"tool": "near", "when": {"/amount": {"==": 9007199254740992}}},
                {"tool": "nearin", "when": {"/amount": {"in": [9007199254740992]}}}
              ]}}]}
            """#.utf8)).get()
        var harness = GatewayHarness(configuration)
        _ = harness.ready()

        func call(_ id: Int, _ tool: String, _ amount: String) -> [MCPGatewayOutput] {
            harness.client(
                #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":{"amount":\#(amount)}}}"#)
        }
        func denied(_ id: Int, _ tool: String, _ amount: String) {
            let reply = call(id, tool, amount)
            #expect(reply.toUpstream.isEmpty, "\(tool) \(amount)")
            #expect(reply.audits.first?.decision == .deny, "\(tool) \(amount)")
            #expect(reply.toClient.first?.compactText.contains(amount) == false, "\(tool) \(amount)")
        }

        denied(1, "eq", "9007199254740993.0")
        denied(2, "eq", "9007199254740993e0")
        denied(3, "eq", "9.007199254740993e15")
        denied(4, "eq", "9007199254740993")
        denied(5, "mem", "9007199254740993.0")
        denied(6, "mem", "-9007199254740993.0")
        denied(7, "gt", "9007199254740993.0")
        denied(8, "gt", "9007199254740993")
        denied(9, "neg", "-9007199254740993.0")
        denied(10, "wide", "4611686018427387905.0")
        denied(11, "wide", "4611686018427387905")
        denied(12, "rounded", "9007199254740996")

        let unsafe = call(13, "pass", "9007199254740993.5")
        #expect(unsafe.toUpstream.isEmpty)
        #expect(unsafe.audits.first?.reason?.contains("cannot read exactly") == true)
        #expect(unsafe.toClient.first?.compactText.contains("9007199254740993.5") == false)

        let missed = call(14, "pass", "9007199254740993.0")
        #expect(missed.audits.isEmpty)
        #expect(missed.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("9007199254740993"))
        #expect(missed.toUpstream.first?.1.compactText.contains("9007199254740993.0") == false)

        let notTheRoundedValue = call(15, "near", "9007199254740993.0")
        #expect(notTheRoundedValue.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("9007199254740993"))
        let notInTheRoundedList = call(16, "nearin", "9007199254740993e0")
        #expect(notInTheRoundedList.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("9007199254740993"))

        let askedMiss = call(17, "note", "2.0")
        #expect(askedMiss.audits.isEmpty)
        #expect(askedMiss.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("2"))

        let reentered = harness.client(#"""
            {"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"rv_call_tool","arguments":{"name":"eq","arguments":{"amount":9007199254740993.0}}}}
            """#)
        #expect(reentered.toUpstream.isEmpty)
        #expect(reentered.audits.first?.decision == .deny)
        #expect(reentered.audits.first?.tool == "eq")
        #expect(reentered.toClient.first?.compactText.contains("9007199254740993.0") == false)

        func unreadable(_ id: Int, _ spelling: String) {
            let reply = call(id, "pass", spelling)
            #expect(reply.toUpstream.isEmpty, "\(spelling)")
            #expect(reply.audits.first?.reason?.contains("cannot read exactly") == true, "\(spelling)")
            #expect(reply.toClient.first?.compactText.contains(spelling) == false, "\(spelling)")
        }
        unreadable(19, "9007199254740991.4")
        unreadable(20, "9007199254740990.1")
        unreadable(21, "9007199254740990.9")
        unreadable(22, "-9007199254740990.1")
        unreadable(23, "4503599627370496.4")
        unreadable(24, "1.0000000000000001")
        unreadable(26, "2251799813685248.4")
        unreadable(27, "2251799813685248.6")
        unreadable(28, "4503599627370495.4")
        unreadable(29, "4503599627370495.6")
        unreadable(30, "12.500000000000001")

        let genuine = call(25, "pass", "12.5")
        #expect(genuine.audits.isEmpty)
        #expect(genuine.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("12.5"))
        let trailing = call(31, "pass", "12.50")
        #expect(trailing.audits.isEmpty)
        #expect(trailing.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("12.50"))
        let half = call(32, "pass", "2251799813685248.5")
        #expect(half.audits.isEmpty)
        #expect(half.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("2251799813685248.5"))
        let otherHalf = call(33, "pass", "4503599627370495.5")
        #expect(otherHalf.audits.isEmpty)
        #expect(otherHalf.toUpstream.first?.1["params"]?["arguments"]?["amount"] == .number("4503599627370495.5"))
    }

    @Test func canonicalHashIgnoresKeyOrder() throws {
        let a = try JSONValue.parse(#"{"b":[1,{"y":2,"x":1}],"a":"s"}"#)
        let b = try JSONValue.parse(#"{"a":"s","b":[1,{"x":1,"y":2}]}"#)
        #expect(a.canonicalHash == b.canonicalHash)
        #expect(a.canonicalHash != (try JSONValue.parse(#"{"a":"t","b":[1,{"x":1,"y":2}]}"#)).canonicalHash)
    }
}
