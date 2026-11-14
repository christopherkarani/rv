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
