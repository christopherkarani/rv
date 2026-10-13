import Foundation
import Testing
@testable import RVMCP

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsKeyOrderAndNumberSpelling() throws {
        let text = #"{"z":1,"a":[1.50,-0,2e10,true,null],"m":{"k":"v"}}"#
        let value = try JSONValue.parse(text)
        #expect(value.compactText == text)
        #expect(value["z"]?.intValue == 1)
        #expect(value["a"]?.arrayValue?.first == .number("1.50"))
    }

    @Test func escapesSoCompactTextIsOneLine() throws {
        let value = JSONValue.string("line1\nline2\u{2028}\"q\"\\\u{01}")
        let text = value.compactText
        #expect(text.contains("\n") == false)
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func decodesUnicodeEscapesIncludingSurrogatePairs() throws {
        #expect(try JSONValue.parse(#""\u00e9\ud83d\ude00\/""#) == .string("é😀/"))
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#""\ud83d""#) }
    }

    @Test func rejectsMalformedInput() {
        for bad in ["", "{", #"{"a":}"#, "[1,]", "01", "1.", "tru", "\"a\u{01}\"", #"{"a":1}x"#, "// c\n1"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try JSONValue.parse(bad) }
        }
    }

    @Test func lenientAcceptsCommentsAndTrailingCommas() throws {
        let text = """
            // servers
            { "servers": { /* one */ "a": { "command": "x", }, }, }
            """
        let value = try JSONValue.parse(text, lenient: true)
        #expect(value["servers"]?["a"]?["command"] == .string("x"))
    }

    @Test func enforcesDepth() {
        let deep = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        #expect(throws: JSONParseError.tooDeep) { try JSONValue.parse(deep) }
        #expect((try? JSONValue.parse(deep, maximumDepth: 80)) != nil)
    }

    @Test func objectEqualityIgnoresOrderButOutputKeepsIt() throws {
        let a = try JSONValue.parse(#"{"x":1,"y":2}"#)
        let b = try JSONValue.parse(#"{"y":2,"x":1}"#)
        #expect(a == b)
        #expect(b.compactText == #"{"y":2,"x":1}"#)
    }

    @Test func prettyTextParsesBack() throws {
        let value = try JSONValue.parse(#"{"a":[1,{"b":[]}],"c":{}}"#)
        #expect(value.prettyText.hasSuffix("\n"))
        #expect(try JSONValue.parse(value.prettyText) == value)
    }
}

@Suite("MiniTOML")
struct MiniTOMLTests {
    static let codexLike = #"""
        model = "gpt-5"
        notify = ["say", "done"] # trailing comment

        [projects."/Users/me/a b"]
        trust_level = "trusted"

        [profiles.fast]
        instructions = """
        Multi-line "quoted" text
        with [brackets] and = signs
        """
        literal = '''raw \n stays'''

        [[skills]]
        name = "ignored"

        [mcp_servers.context7]
        command = "npx"
        args = [
            "-y",
            "@upstash/context7-mcp", # comment inside an array
            "--api-key",
            "ctx7sk-00000000-1111-2222-3333-444444444444",
        ]

        [mcp_servers.stripe]
        url = "https://mcp.stripe.com"
        enabled = false

        [mcp_servers.node]
        command = '/opt/bin/node_repl'
        startup_timeout_sec = 120
        env = { A = "1", "B.C" = 'two' }

        [mcp_servers.node.env]
        D = "\u00e9\t"
        """#

    @Test func readsMCPServerTablesAroundOtherContent() throws {
        let root = try MiniTOML.parse(Self.codexLike)
        let servers = try #require(root["mcp_servers"]?.tableValue)
        #expect(Set(servers.keys) == ["context7", "stripe", "node"])
        #expect(servers["context7"]?["args"]?.stringArray?.count == 4)
        #expect(servers["stripe"]?["enabled"]?.boolValue == false)
        #expect(servers["node"]?["command"]?.stringValue == "/opt/bin/node_repl")
        #expect(servers["node"]?["env"]?["D"]?.stringValue == "é\t")
        #expect(root["projects"]?["/Users/me/a b"]?["trust_level"]?.stringValue == "trusted")
        #expect(root["profiles"]?["fast"]?["instructions"]?.stringValue?.hasPrefix("Multi-line \"quoted\"") == true)
        #expect(root["profiles"]?["fast"]?["literal"]?.stringValue == #"raw \n stays"#)
        #expect(root["skills"] == nil)
    }

    @Test func reportsTheLineOfASyntaxError() {
        #expect(throws: MiniTOMLError(line: 3)) { try MiniTOML.parse("a = 1\n\nb = \"unterminated\n") }
    }
}
