import Foundation
import Testing
@testable import RVMCP

/// Protocol payloads reach the client as the upstream sent them (after
/// secret scrubbing): schemas and tool results are data, not display text.
@Suite("MCPGatewayCore payload fidelity")
struct MCPGatewayFidelityTests {
    static let files = MCPServerDefinition(name: "files", command: "files-mcp", tools: MCPToolPolicy(allow: ["*"]))

    static func listed(_ harness: inout GatewayHarness, tools: String) -> [JSONValue] {
        let list = harness.client(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let id = list.toUpstream.first?.1["id"]?.intValue ?? -1
        return harness.upstream("files", #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":\#(tools)}}"#)
            .toClient.first?["result"]?["tools"]?.arrayValue ?? []
    }

    @Test func inputSchemaWithABackslashRegexRoundTripsUnchanged() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        // JSON text: the pattern is ^[A-Za-z]:\\[^\n]+$ with real backslashes.
        let schema = #"{"type":"object","properties":{"path":{"type":"string","pattern":"^[A-Za-z]:\\\\[^\\n]+$","description":"Windows path\nfirst line only"}},"required":["path"]}"#
        let output = #"{"type":"object","properties":{"lines":{"type":"string","pattern":"\\d+\\s*"}}}"#
        let tools = Self.listed(
            &harness,
            tools: #"[{"name":"read","description":"Read a file","inputSchema":\#(schema),"outputSchema":\#(output)}]"#)
        let tool = try #require(tools.first)
        #expect(tool["inputSchema"] == (try JSONValue.parse(schema)))
        #expect(tool["outputSchema"] == (try JSONValue.parse(output)))
        let pattern = try #require(tool["inputSchema"]?["properties"]?["path"]?["pattern"]?.stringValue)
        #expect(pattern == "^[A-Za-z]:\\\\[^\\n]+$")
        #expect(try NSRegularExpression(pattern: pattern).firstMatch(
            in: "C:\\dir", range: NSRange(location: 0, length: 6)) != nil)
    }

    @Test func multiLineToolResultRoundTripsUnchanged() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":"r","method":"tools/call","params":{"name":"read","arguments":{"path":"a"}}}"#)
        let id = try #require(call.toUpstream.first?.1["id"]?.intValue)
        let result = #"{"content":[{"type":"text","text":"line one\nline two\n\tC:\\dir\\file \u001b[1mbold\u001b[0m\r\n"},{"type":"resource","resource":{"uri":"file:///a","text":"x = \"\\\\\"\n"}}],"structuredContent":{"rows":["a\nb","c\\d"]}}"#
        let reply = harness.upstream("files", #"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#)
        let message = try #require(reply.toClient.first)
        #expect(message["id"] == .string("r"))
        #expect(message["result"] == (try JSONValue.parse(result)))
        #expect(message["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
            == "line one\nline two\n\tC:\\dir\\file \u{1B}[1mbold\u{1B}[0m\r\n")
        // The wire stays one JSON line with no raw controls or separators.
        let wire = message.compactText
        #expect(wire.contains("\n") == false)
        #expect(wire.unicodeScalars.contains { $0.value < 0x20 } == false)
        #expect(try JSONValue.parse(wire) == message)
    }

    @Test func upstreamErrorRoundTripsUnchanged() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        let call = harness.client(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read","arguments":{}}}"#)
        let id = try #require(call.toUpstream.first?.1["id"]?.intValue)
        let error = #"{"code":-32000,"message":"bad path C:\\x\nsee docs","data":{"pattern":"\\w+"}}"#
        let reply = harness.upstream("files", #"{"jsonrpc":"2.0","id":\#(id),"error":\#(error)}"#)
        #expect(reply.toClient.first?["error"] == (try JSONValue.parse(error)))
    }

    @Test func wireEscapesEveryDisplayHazardAsJSONButDecodesFaithfully() throws {
        let hazards = "a\u{85}b\u{2028}c\u{200E}d\u{E0041}e\u{FEFF}f\u{9B}2J"
        let value = JSONValue.string(hazards)
        let wire = value.compactText
        let raw: Set<UInt32> = [0x85, 0x2028, 0x200E, 0xE0041, 0xFEFF, 0x9B]
        #expect(wire.unicodeScalars.contains { raw.contains($0.value) } == false)
        #expect(wire.contains("\\u0085"))
        #expect(wire.contains("\\udb40\\udc41"))
        #expect(try JSONValue.parse(wire) == value)
    }

    @Test func descriptionsKeepLineBreaksAndBackslashesButNeutraliseHiddenControls() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        let tools = Self.listed(
            &harness,
            tools: #"[{"name":"read","title":"Read\u202e elif","description":"Reads a file.\nMatches \\d+ \ttabs\r\u001b[2J\u202eevil\udb40\udc41\u200b\u200d end"}]"#)
        let tool = try #require(tools.first)
        #expect(tool["description"]?.stringValue
            == "Reads a file.\nMatches \\d+ \ttabs\\u000d\\u001b[2J\\u202eevil\\ue0041\\u200b\u{200D} end")
        #expect(tool["title"]?.stringValue == "Read\\u202e elif")
        #expect(MCPDisplayedText.description("plain\\text\nnext") == "plain\\text\nnext")
    }

    /// M2: every `description`/`title` string anywhere in a schema loses
    /// hiding scalars; `pattern`, `const`, `enum`, `default` and `examples`
    /// stay byte-exact, and so does a property that is named `description`.
    @Test func schemaProseLosesHidingScalarsButSchemaValuesStayExact() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        let hidden = #"x‮y󠁁\u001b[2Jz\nnext"#
        let schema = #"{"type":"object","title":"T\#(hidden)","description":"D\#(hidden)","properties":{"path":{"type":"string","description":"P\#(hidden)","pattern":"^\\d+‮$","const":"c‮","enum":["e‮"],"default":{"description":"d‮"},"examples":["x‮"]},"description":{"type":"string","title":"N\#(hidden)"}},"$defs":{"item":{"description":"I\#(hidden)"}},"anyOf":[{"description":"A\#(hidden)"}]}"#
        let output = #"{"type":"object","properties":{"ok":{"type":"boolean","description":"O\#(hidden)"}}}"#
        let tools = Self.listed(
            &harness, tools: #"[{"name":"read","description":"Read","inputSchema":\#(schema),"outputSchema":\#(output)}]"#)
        let tool = try #require(tools.first)
        let raw = try JSONValue.parse(#""\#(hidden)""#).stringValue ?? ""
        let shown = MCPDisplayedText.description(raw)
        #expect(shown.contains("\n"))
        #expect(shown.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0xE0041 || $0.value == 0x1B } == false)
        let input = try #require(tool["inputSchema"])
        #expect(input["title"]?.stringValue == "T" + shown)
        #expect(input["description"]?.stringValue == "D" + shown)
        #expect(input["properties"]?["path"]?["description"]?.stringValue == "P" + shown)
        #expect(input["properties"]?["description"]?["title"]?.stringValue == "N" + shown)
        #expect(input["$defs"]?["item"]?["description"]?.stringValue == "I" + shown)
        #expect(input["anyOf"]?.arrayValue?.first?["description"]?.stringValue == "A" + shown)
        #expect(tool["outputSchema"]?["properties"]?["ok"]?["description"]?.stringValue == "O" + shown)
        let original = try JSONValue.parse(schema)
        for key in ["pattern", "const", "enum", "default", "examples"] {
            #expect(input["properties"]?["path"]?[key] == original["properties"]?["path"]?[key])
        }
        #expect(input["properties"]?["path"]?["pattern"]?.stringValue == "^\\d+\u{202E}$")
    }

    /// The client's reply is rebuilt from the upstream's `result` or
    /// `error`; nothing else the upstream put in its message is forwarded.
    @Test func aCallReplyCarriesOnlyTheResultOrTheError() throws {
        var harness = GatewayHarness(MCPConfiguration(servers: [Self.files]))
        _ = harness.ready()
        func call(_ reply: String) throws -> JSONValue {
            let request = harness.client(#"{"jsonrpc":"2.0","id":"r","method":"tools/call","params":{"name":"read","arguments":{}}}"#)
            let id = try #require(request.toUpstream.first?.1["id"]?.intValue)
            return try #require(harness.upstream("files", reply.replacingOccurrences(of: "ID", with: "\(id)")).toClient.first)
        }
        let result = try call(#"{"jsonrpc":"2.0","id":ID,"result":{"content":[]},"params":{"x":1},"_meta":{"note":"unshown"},"extra":"y"}"#)
        #expect(result == (try JSONValue.parse(#"{"jsonrpc":"2.0","id":"r","result":{"content":[]}}"#)))
        let error = try call(#"{"jsonrpc":"1.0","id":ID,"error":{"code":-1,"message":"no"},"extra":"y"}"#)
        #expect(error == (try JSONValue.parse(#"{"jsonrpc":"2.0","id":"r","error":{"code":-1,"message":"no"}}"#)))
        let neither = try call(#"{"jsonrpc":"2.0","id":ID,"extra":"y"}"#)
        #expect(neither["error"]?["code"]?.intValue == -32603)
        #expect(neither["extra"] == nil)
    }

    /// M2 (a): the approval prompt shows argument text escaped.
    @Test func theApprovalPromptEscapesHidingScalarsInArguments() throws {
        let arguments = try JSONValue.parse(#"{"note":"a\u001b[2Jb‮c󠁁d"}"#)
        let message = MCPGatewayCore.elicitationMessage(server: "files", tool: "wri\u{202E}te", arguments: arguments)
        #expect(message.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E || $0.value == 0xE0041 } == false)
        #expect(MCPGatewayCore.elicitationCovers(arguments, shown: message))
    }

    @Test func secretsAreStillScrubbedFromSchemasAndResults() throws {
        var harness = GatewayHarness(
            MCPConfiguration(servers: [Self.files]), secrets: ["files": [("TOKEN", "tok\\en\nvalue")]])
        _ = harness.ready()
        let tools = Self.listed(
            &harness,
            tools: #"[{"name":"read","inputSchema":{"type":"object","default":"tok\\en\nvalue"}}]"#)
        #expect(tools.first?["inputSchema"]?["default"] == .string("[redacted:TOKEN]"))
        let call = harness.client(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read","arguments":{}}}"#)
        let id = try #require(call.toUpstream.first?.1["id"]?.intValue)
        let reply = harness.upstream(
            "files", #"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"a\ntok\\en\nvalue\nb"}]}}"#)
        #expect(reply.toClient.first?["result"]?["content"]?.arrayValue?.first?["text"]
            == .string("a\n[redacted:TOKEN]\nb"))
    }
}
