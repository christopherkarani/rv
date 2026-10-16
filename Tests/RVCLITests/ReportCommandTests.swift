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

    @Test func failingHostServerNameIsEscaped() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "x\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
        let report = ReportRun.Report(
            schema: ReportRun.schema,
            generatedAt: "2026-01-01T00:00:00Z",
            rv: .init(version: "0.0.0", platform: "linux"),
            host: .init(name: "build", user: "me", uid: 1),
            managed: .init(
                state: "none", directory: "/tmp/managed", reason: nil, organization: nil,
                serial: nil, sha256: nil, signed: nil, restrictions: nil),
            config: [],
            mcp: .init(
                ok: false, error: nil, servers: 1, counts: ["unreviewed": 1],
                failing: [.init(host: "cursor", name: raw, status: "unreviewed", config: "/tmp/mcp.json")],
                plaintextCredentials: 0),
            secrets: .init(error: nil, items: []),
            audit: .init(since: "2026-01-01T00:00:00Z", total: 0, byKind: [:], lastEventAt: nil),
            sandbox: .init(platform: "linux", mcpSandbox: false, peerTrustInstalled: false))
        let text = ReportRun.text(report)
        #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x2029 } == false)
        #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
        #expect(text.contains("unreviewed"))
        #expect(text.contains("\\u001b[2J"))
        #expect(text.contains("\\u2028"))
        #expect(text.contains("\\u2029"))
        #expect(text.contains("\\u202e"))
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
        #expect(lines.contains(sentence) == false)
        let json = ReportRun.json(report)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let mcp = try #require(parsed["mcp"] as? [String: Any])
        let failing = try #require(mcp["failing"] as? [[String: Any]])
        #expect(failing.first?["name"] as? String == raw)
    }

    @Test func mcpErrorPathIsEscaped() throws {
        let sentence = "ok: every MCP server is governed by rv, allowed direct, or disabled"
        let raw = "/tmp/h\u{1B}[2J\u{1B}[H" + sentence + "\u{2028}" + sentence + "\u{2029}" + sentence + "\u{202E}" + sentence
        let error = raw + "/.cursor/mcp.json: not a regular file"
        func report(counts: [String: Int]) -> ReportRun.Report {
            ReportRun.Report(
                schema: ReportRun.schema,
                generatedAt: "2026-01-01T00:00:00Z",
                rv: .init(version: "0.0.0", platform: "linux"),
                host: .init(name: "build", user: "me", uid: 1),
                managed: .init(
                    state: "none", directory: "/tmp/managed", reason: nil, organization: nil,
                    serial: nil, sha256: nil, signed: nil, restrictions: nil),
                config: [],
                mcp: .init(ok: false, error: error, servers: 0, counts: counts, failing: [], plaintextCredentials: 0),
                secrets: .init(error: nil, items: []),
                audit: .init(since: "2026-01-01T00:00:00Z", total: 0, byKind: [:], lastEventAt: nil),
                sandbox: .init(platform: "linux", mcpSandbox: false, peerTrustInstalled: false))
        }
        for counts in [[String: Int](), ["unreviewed": 1]] {
            let text = ReportRun.text(report(counts: counts))
            #expect(text.unicodeScalars.contains { $0.value == 0x1B } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x2028 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x2029 } == false)
            #expect(text.unicodeScalars.contains { $0.value == 0x202E } == false)
            #expect(text.contains("\\u001b[2J"))
            #expect(text.contains("\\u2028"))
            #expect(text.contains("\\u2029"))
            #expect(text.contains("\\u202e"))
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }).map(String.init)
            #expect(lines.contains(sentence) == false)
        }
        let json = ReportRun.json(report(counts: [:]))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let mcp = try #require(parsed["mcp"] as? [String: Any])
        #expect(mcp["error"] as? String == error)
    }
}
