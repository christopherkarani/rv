import Foundation
import Testing
import RVDomain
@testable import RVCLI

struct ReportCommandTests {
    @Test func hostUserIsEscapedInTextAndRobotJSON() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{202E}" + sentence
        let report = ReportRun.Report(
            schema: ReportRun.schema,
            generatedAt: "2026-01-01T00:00:00Z",
            rv: .init(version: "0.0.0", platform: "linux"),
            host: .init(name: "build", user: raw, uid: 1),
            managed: .init(
                state: "none", directory: "/tmp/managed", reason: nil, organization: nil,
                serial: nil, sha256: nil, signed: nil, restrictions: nil),
            config: [],
            mcp: .init(ok: true, error: nil, servers: 0, counts: [:], failing: [], plaintextCredentials: 0),
            secrets: .init(error: nil, items: []),
            audit: .init(since: "2026-01-01T00:00:00Z", total: 0, byKind: [:], lastEventAt: nil),
            sandbox: .init(platform: "linux", mcpSandbox: false, peerTrustInstalled: false))
        let text = ReportRun.text(report)
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("on build ("))
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u202e"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
        let json = ReportRun.json(report)
        #expect(json.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(json.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(json.contains("\\u2028"))
        #expect(json.contains("\\u202e"))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let host = try #require(parsed["host"] as? [String: Any])
        #expect(host["user"] as? String == raw)
    }
}
